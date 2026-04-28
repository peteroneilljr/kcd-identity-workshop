const express = require('express');
const fs = require('fs');
const crypto = require('crypto');
const forge = require('node-forge');

const app = express();
const PORT = process.env.PORT || 3005;
const SERVICE_NAME = process.env.SERVICE_NAME || 'pg-ca';
const CA_KEY_PATH = process.env.PG_CA_KEY  || '/etc/pg-ca/ca.key';
const CA_CERT_PATH = process.env.PG_CA_CERT || '/etc/pg-ca-cert/ca.crt';
const VALIDITY_MINUTES = parseInt(process.env.CERT_VALIDITY_MIN || '15', 10);

// Identities the CA will sign for. Their CN goes into the cert's subject;
// Postgres' `cert` auth requires CN == requested DB user.
const ALLOWED = new Set(['alice', 'bob']);

// CSR comes in as PEM text body.
app.use(express.text({ type: '*/*', limit: '16kb' }));

let caKey, caCert;
try {
  caKey  = forge.pki.privateKeyFromPem(fs.readFileSync(CA_KEY_PATH, 'utf8'));
  caCert = forge.pki.certificateFromPem(fs.readFileSync(CA_CERT_PATH, 'utf8'));
} catch (e) {
  console.error(`failed to load CA material: ${e.message}`);
  process.exit(1);
}

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

app.use((req, res, next) => {
  const user = jwtUsername(req) || 'anon';
  console.log(`[${new Date().toISOString()}] user=${user} ${req.method} ${req.path}`);
  next();
});

app.get('/health', (_req, res) => {
  res.json({ status: 'healthy', service: SERVICE_NAME });
});

// Signs a CSR. Ignores any subject in the CSR — substitutes CN=<JWT username>
// so a client can't request a cert for someone else.
app.post('/sign', (req, res) => {
  const user = jwtUsername(req);
  if (!user) return res.status(401).json({ error: 'no jwt identity' });
  if (!ALLOWED.has(user)) {
    return res.status(403).json({ error: `no DB role provisioned for '${user}'` });
  }

  const csrPem = String(req.body || '').trim();
  let csr;
  try {
    csr = forge.pki.certificationRequestFromPem(csrPem);
    if (!csr.verify()) throw new Error('CSR self-signature invalid');
  } catch (e) {
    return res.status(400).json({ error: `invalid CSR: ${e.message}` });
  }

  const cert = forge.pki.createCertificate();
  cert.publicKey = csr.publicKey;
  cert.serialNumber = forge.util.bytesToHex(forge.random.getBytesSync(16));
  cert.validity.notBefore = new Date();
  cert.validity.notAfter  = new Date(Date.now() + VALIDITY_MINUTES * 60_000);

  // Subject CN = JWT preferred_username. PG `cert` auth checks CN == user.
  cert.setSubject([{ name: 'commonName', value: user }]);
  cert.setIssuer(caCert.subject.attributes);
  cert.setExtensions([
    { name: 'basicConstraints', cA: false },
    { name: 'keyUsage', digitalSignature: true, keyEncipherment: true },
    { name: 'extKeyUsage', clientAuth: true },
  ]);

  cert.sign(caKey, forge.md.sha256.create());
  res.type('text/plain').send(forge.pki.certificateToPem(cert));
});

app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', service: SERVICE_NAME, path: req.path });
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`${SERVICE_NAME} listening on ${PORT} (cert validity ${VALIDITY_MINUTES}m)`);
});

const shutdown = () => server.close(() => process.exit(0));
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
