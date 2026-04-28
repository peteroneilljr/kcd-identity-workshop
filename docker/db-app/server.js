const express = require('express');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3003;
const SERVICE_NAME = process.env.SERVICE_NAME || 'db-app';

// Identities allowed to be assumed via SET ROLE. The proxy role
// (PGUSER) holds GRANTs to these roles in init.sql.
const ALLOWED_ROLES = new Set(['alice', 'bob']);

const pool = new Pool({
  host: process.env.PGHOST,
  port: parseInt(process.env.PGPORT || '5432', 10),
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE,
  max: 10,
  idleTimeoutMillis: 30000,
});

pool.on('error', (err) => {
  console.error('Unexpected pg pool error:', err);
});

function jwtUsername(req) {
  const raw = req.headers['x-jwt-payload'];
  if (!raw) return null;
  try {
    const decoded = JSON.parse(Buffer.from(raw, 'base64').toString());
    return decoded.preferred_username || null;
  } catch (e) {
    console.error('failed to decode x-jwt-payload:', e.message);
    return null;
  }
}

// Log every request with the JWT identity (if any) so Loki/Promtail
// can ship structured per-user audit entries.
app.use((req, res, next) => {
  const user = jwtUsername(req) || 'anon';
  console.log(`[${new Date().toISOString()}] user=${user} ${req.method} ${req.path}`);
  next();
});

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'healthy', service: SERVICE_NAME, db: 'reachable' });
  } catch (e) {
    res.status(503).json({ status: 'unhealthy', service: SERVICE_NAME, error: e.message });
  }
});

app.get('/', async (req, res) => {
  const user = jwtUsername(req);
  if (!user) {
    return res.status(401).json({ error: 'no jwt identity in x-jwt-payload' });
  }
  if (!ALLOWED_ROLES.has(user)) {
    return res.status(403).json({ error: `no DB role provisioned for user '${user}'` });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Quoted identifier; user has been validated against ALLOWED_ROLES.
    await client.query(`SET LOCAL ROLE "${user}"`);
    const r = await client.query(
      'SELECT id, owner, title, body FROM documents ORDER BY id'
    );
    await client.query('COMMIT');
    res.json({
      service: SERVICE_NAME,
      authenticated_user: user,
      db_role: user,
      visible_documents: r.rows,
    });
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('query failed:', e);
    res.status(500).json({ error: e.message });
  } finally {
    client.release();
  }
});

app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', service: SERVICE_NAME, path: req.path });
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`${SERVICE_NAME} listening on ${PORT}`);
});

const shutdown = () => {
  server.close(() => pool.end().then(() => process.exit(0)));
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
