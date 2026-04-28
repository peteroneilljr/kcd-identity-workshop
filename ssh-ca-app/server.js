const express = require('express');
const { execFile } = require('child_process');
const fs = require('fs').promises;
const fssync = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3004;
const SERVICE_NAME = process.env.SERVICE_NAME || 'ssh-ca';
const CA_KEY_PATH = process.env.SSH_CA_KEY || '/etc/ssh-ca/ca';
const CERT_VALIDITY = process.env.CERT_VALIDITY || '+15m';

// Identities the CA will sign for. The cert principal is set to the JWT's
// preferred_username; sshd matches that against AuthorizedPrincipalsFile.
const ALLOWED = new Set(['alice', 'bob']);

// Accept the user's pubkey as a raw text body (mirrors `ssh-keygen` UX).
app.use(express.text({ type: '*/*', limit: '8kb' }));

app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
  next();
});

app.get('/health', (_req, res) => {
  // Don't leak existence/path of CA key — just report process health.
  const ok = fssync.existsSync(CA_KEY_PATH);
  res.status(ok ? 200 : 503).json({ status: ok ? 'healthy' : 'unhealthy', service: SERVICE_NAME });
});

function jwtUsername(req) {
  const raw = req.headers['x-jwt-payload'];
  if (!raw) return null;
  try {
    return JSON.parse(Buffer.from(raw, 'base64').toString()).preferred_username || null;
  } catch (e) {
    console.error('failed to decode x-jwt-payload:', e.message);
    return null;
  }
}

// Single-line OpenSSH public key, e.g. "ssh-ed25519 AAAA... comment"
const SSH_PUBKEY_RE =
  /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/=]+( [^\r\n]+)?$/;

app.post('/sign', async (req, res) => {
  const user = jwtUsername(req);
  if (!user) return res.status(401).json({ error: 'no jwt identity' });
  if (!ALLOWED.has(user)) {
    return res.status(403).json({ error: `no principal mapping for '${user}'` });
  }

  const pubkey = String(req.body || '').trim();
  if (!SSH_PUBKEY_RE.test(pubkey)) {
    return res.status(400).json({ error: 'invalid SSH public key (single line, supported types only)' });
  }

  let dir;
  try {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'sshca-'));
    const userKey = path.join(dir, 'user.pub');
    await fs.writeFile(userKey, pubkey + '\n', { mode: 0o600 });

    const certId = `${user}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;

    await new Promise((resolve, reject) => {
      execFile(
        'ssh-keygen',
        ['-q', '-s', CA_KEY_PATH, '-I', certId, '-n', user, '-V', CERT_VALIDITY, userKey],
        (err, _stdout, stderr) => (err ? reject(new Error(stderr || err.message)) : resolve()),
      );
    });

    const cert = await fs.readFile(path.join(dir, 'user-cert.pub'), 'utf8');
    res.type('text/plain').send(cert);
  } catch (e) {
    console.error('signing failed:', e.message);
    res.status(500).json({ error: 'signing failed' });
  } finally {
    if (dir) await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
});

app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', service: SERVICE_NAME, path: req.path });
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`${SERVICE_NAME} listening on ${PORT}`);
});

const shutdown = () => server.close(() => process.exit(0));
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
