const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;
const SERVICE_NAME = process.env.SERVICE_NAME || 'public-app';

// Middleware to log all requests
app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.path} - User: ${req.headers['x-forwarded-user'] || 'anonymous'}`);
  next();
});

// Health check endpoint (no authentication required)
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    service: SERVICE_NAME,
    timestamp: new Date().toISOString()
  });
});

// Main endpoint
app.get('/', (req, res) => {
  const user = req.headers['x-forwarded-user'] || 'anonymous';
  const roles = req.headers['x-forwarded-roles'] || 'none';

  // Parse JWT payload if forwarded by Envoy
  let jwtPayload = null;
  if (req.headers['x-jwt-payload']) {
    try {
      jwtPayload = JSON.parse(Buffer.from(req.headers['x-jwt-payload'], 'base64').toString());
    } catch (e) {
      console.error('Failed to parse JWT payload:', e);
    }
  }

  const response = {
    service: SERVICE_NAME,
    message: `Welcome to the ${SERVICE_NAME}!`,
    description: 'This is a public service accessible to any authenticated user.',
    authenticated_user: user,
    roles: roles,
    timestamp: new Date().toISOString(),
    request: {
      method: req.method,
      path: req.path,
      headers: {
        'user-agent': req.headers['user-agent'],
        'x-forwarded-user': user,
        'x-forwarded-roles': roles
      }
    }
  };

  // Include JWT claims if available
  if (jwtPayload) {
    response.jwt_claims = {
      username: jwtPayload.preferred_username,
      email: jwtPayload.email,
      realm_roles: jwtPayload.realm_access?.roles || []
    };
  }

  res.json(response);
});

// Catch-all for undefined routes
app.use((req, res) => {
  res.status(404).json({
    error: 'Not Found',
    service: SERVICE_NAME,
    path: req.path
  });
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`${SERVICE_NAME} listening on port ${PORT}`);
  console.log(`Health check available at http://localhost:${PORT}/health`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM signal received: closing HTTP server');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT signal received: closing HTTP server');
  process.exit(0);
});
