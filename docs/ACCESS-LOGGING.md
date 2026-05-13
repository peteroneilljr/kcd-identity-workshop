# Access Logging with Identity Explained

This document explains how Envoy's access logger captures user identity from JWT tokens and includes it in audit logs, creating a complete trail of who accessed what resources.

![The JWT auth filter stores claims (user, email, roles) in Envoy's dynamic metadata; the RBAC filter and access logger both read from that metadata, and the logger emits a JSON line tying every request to the authenticated identity](../assets/ACCESS-LOGGING.svg)

## Table of Contents

1. [Overview](#overview)
2. [The Configuration](#the-configuration)
3. [How It Works: Dynamic Metadata](#how-it-works-dynamic-metadata)
4. [Complete Flow Example](#complete-flow-example)
5. [Format String Syntax](#format-string-syntax)
6. [Different Scenarios](#different-scenarios)
7. [Viewing and Analyzing Logs](#viewing-and-analyzing-logs)
8. [Security Benefits](#security-benefits)

---

## Overview

The access logging system in our demo provides **identity-aware audit logs** by:

1. **JWT Authentication Filter** extracts user identity from tokens
2. **Dynamic Metadata** stores identity information during request processing
3. **Access Logger** reads metadata and outputs structured logs with user context

**Result**: Every request is logged with the user's identity, creating an audit trail for security, compliance, and debugging.

---

## The Configuration

### Access Logger Configuration

From [envoy/envoy.yaml](./envoy/envoy.yaml):

```yaml
access_log:
- name: envoy.access_loggers.stdout
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
    log_format:
      json_format:
        timestamp: "%START_TIME%"
        method: "%REQ(:METHOD)%"
        path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
        status: "%RESPONSE_CODE%"
        duration_ms: "%DURATION%"
        user: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:preferred_username)%"
        roles: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:realm_access:roles)%"
        response_flags: "%RESPONSE_FLAGS%"
```

### JWT Filter Configuration

The JWT filter is configured to store claims in metadata:

```yaml
jwt_authn:
  providers:
    keycloak:
      issuer: "http://localhost:8180/realms/demo"
      remote_jwks:
        http_uri:
          uri: "http://keycloak:8180/realms/demo/protocol/openid-connect/certs"
      payload_in_metadata: "jwt_payload"  # ← CRITICAL: Stores JWT in metadata
      forward_payload_header: "x-jwt-payload"
```

**Key Setting**: `payload_in_metadata: "jwt_payload"`

This tells Envoy to:
- Extract the entire JWT payload
- Store it in dynamic metadata under the key `"jwt_payload"`
- Make it available to other filters and the access logger

---

## How It Works: Dynamic Metadata

**Dynamic metadata** is Envoy's mechanism for sharing data between filters during request processing. It acts as a request-scoped key-value store.

### The Flow

```
┌─────────────────────────────────────────────┐
│  Step 1: JWT Authentication Filter          │
│                                             │
│  1. Receives request with JWT token         │
│  2. Validates JWT signature                 │
│  3. Extracts JWT payload (claims)           │
│  4. Stores payload in dynamic metadata      │
│     Key: "jwt_payload"                      │
│     Namespace: "envoy.filters.http.jwt_authn"│
└──────────────┬──────────────────────────────┘
               │
               │ Metadata now contains:
               │ {
               │   "jwt_payload": {
               │     "preferred_username": "alice",
               │     "email": "alice@demo.local",
               │     "realm_access": {
               │       "roles": ["user"]
               │     },
               │     "iss": "http://localhost:8180/realms/demo",
               │     "exp": 1234567890,
               │     ...
               │   }
               │ }
               ▼
┌─────────────────────────────────────────────┐
│  Step 2: RBAC Filter                        │
│                                             │
│  Reads metadata to make authorization       │
│  decision (allow/deny)                      │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Step 3: Router Filter                      │
│                                             │
│  Routes request to backend service          │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Step 4: Access Logger                      │
│                                             │
│  Reads metadata using format string:        │
│  %DYNAMIC_METADATA(                         │
│    envoy.filters.http.jwt_authn:           │ ← Namespace
│    jwt_payload:                            │ ← Key
│    preferred_username                      │ ← Field path
│  )%                                         │
│                                             │
│  Outputs JSON log with identity:            │
│  {                                          │
│    "user": "alice",                         │
│    "path": "/alice",                        │
│    "status": 200                            │
│  }                                          │
└─────────────────────────────────────────────┘
```

### Metadata Structure

The JWT filter stores data in this structure:

```
Namespace: envoy.filters.http.jwt_authn
  └─ Key: jwt_payload
      └─ Value: {
          "iss": "http://localhost:8180/realms/demo",
          "sub": "f1234567-89ab-cdef-0123-456789abcdef",
          "aud": "demo-client",
          "exp": 1234567890,
          "iat": 1234567590,
          "preferred_username": "alice",
          "email": "alice@demo.local",
          "realm_access": {
            "roles": ["user"]
          },
          "session_state": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        }
```

---

## Format String Syntax

### Basic Syntax

```yaml
user: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:preferred_username)%"
```

**Breaking down the format string**:

```
%DYNAMIC_METADATA(                          ← Envoy command to read metadata
  envoy.filters.http.jwt_authn              ← Namespace (which filter)
  :                                         ← Separator
  jwt_payload                               ← Metadata key
  :                                         ← Separator
  preferred_username                        ← JSON path in the payload
)%
```

### Accessing Nested Fields

For nested JSON structures (like roles):

```yaml
roles: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:realm_access:roles)%"
```

This navigates through the JSON structure:

```json
{
  "jwt_payload": {
    "realm_access": {
      "roles": ["user", "admin"]  ← This value is extracted
    }
  }
}
```

### All Available Claims

You can log any JWT claim:

```yaml
json_format:
  # User identity
  user: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:preferred_username)%"
  email: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:email)%"

  # Token metadata
  subject: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:sub)%"
  issuer: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:iss)%"

  # Session info
  session: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:session_state)%"

  # Authorization
  roles: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:realm_access:roles)%"

  # Request info
  timestamp: "%START_TIME%"
  method: "%REQ(:METHOD)%"
  path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
  status: "%RESPONSE_CODE%"
  duration_ms: "%DURATION%"
  response_flags: "%RESPONSE_FLAGS%"
```

---

## Complete Flow Example

### Scenario: Alice Accesses Her App

#### 1. Request Arrives

```http
GET /alice HTTP/1.1
Host: localhost:8080
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
```

#### 2. JWT Filter Processes Token

```
JWT Authentication Filter:
├─ Extracts token from Authorization header
├─ Fetches public key from Keycloak (JWKS endpoint)
├─ Validates signature using RS256 algorithm
├─ Checks expiration (exp claim)
├─ Decodes payload:
│  {
│    "iss": "http://localhost:8180/realms/demo",
│    "sub": "f1234567-89ab-cdef-0123-456789abcdef",
│    "aud": "demo-client",
│    "exp": 1234567890,
│    "iat": 1234567590,
│    "preferred_username": "alice",
│    "email": "alice@demo.local",
│    "realm_access": {
│      "roles": ["user"]
│    }
│  }
└─ Stores in dynamic metadata:
   Namespace: envoy.filters.http.jwt_authn
   Key: jwt_payload
   Value: <decoded JWT payload>
```

#### 3. RBAC Filter Checks Authorization

```yaml
# RBAC reads the same metadata
principals:
- metadata:
    filter: "envoy.filters.http.jwt_authn"  # Same namespace
    path:
    - key: "jwt_payload"                     # Same key
    - key: "preferred_username"              # Navigate to field
    value:
      string_match:
        exact: "alice"
```

**Decision**: ✅ ALLOW (username matches)

#### 4. Router Forwards Request

Request is forwarded to `alice-app` on port 3002.

#### 5. Access Logger Runs

After response is received (200 OK), the access logger processes the format strings:

```yaml
user: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:preferred_username)%"
# Resolves to: "alice"

roles: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:realm_access:roles)%"
# Resolves to: ["user"]
```

#### 6. Log Output

```json
{
  "timestamp": "2024-01-20T10:30:45.123Z",
  "method": "GET",
  "path": "/alice",
  "status": 200,
  "duration_ms": 5,
  "user": "alice",
  "roles": ["user"],
  "response_flags": "-"
}
```

---

## Different Scenarios

### Scenario 1: Invalid JWT (401 Unauthorized)

If the JWT is invalid, expired, or missing:

```json
{
  "timestamp": "2024-01-20T10:31:00.456Z",
  "method": "GET",
  "path": "/alice",
  "status": 401,
  "duration_ms": 2,
  "user": "-",           # ← No user (metadata not set)
  "roles": "-",          # ← No roles (metadata not set)
  "response_flags": "UAEX"  # ← Unauthorized external service
}
```

**Why no user identity?**
- JWT filter rejected the token before validation
- Metadata was never populated
- Access logger has no identity information to read

### Scenario 2: RBAC Denial (403 Forbidden)

Alice tries to access Bob's app:

```json
{
  "timestamp": "2024-01-20T10:32:00.789Z",
  "method": "GET",
  "path": "/bob",
  "status": 403,
  "duration_ms": 3,
  "user": "alice",       # ← User IS logged (JWT was valid)
  "roles": ["user"],     # ← Roles ARE logged
  "response_flags": "RBAC_ACCESS_DENIED"  # ← Why it failed
}
```

**Why user identity IS present?**
- JWT was valid (passed authentication)
- Metadata was populated by JWT filter
- RBAC filter denied access, but metadata persists
- Access logger still reads the identity

**Security value**: We know WHO tried to access WHAT and that it was blocked.

### Scenario 3: Successful Access

Bob accesses his app:

```json
{
  "timestamp": "2024-01-20T10:33:15.234Z",
  "method": "GET",
  "path": "/bob",
  "status": 200,
  "duration_ms": 8,
  "user": "bob",
  "roles": ["user", "admin"],
  "response_flags": "-"
}
```

**Complete audit trail**: Who (bob), what (/bob), when (timestamp), outcome (200).

---

## Viewing and Analyzing Logs

### Real-Time Log Viewing

```bash
# Watch logs as requests come in
docker-compose logs -f envoy

# Filter for specific user
docker-compose logs envoy | grep '"user":"alice"'

# Find all 403 denials
docker-compose logs envoy | grep '"status":403'

# Find all RBAC denials
docker-compose logs envoy | grep 'RBAC_ACCESS_DENIED'

# Find all unauthorized attempts (401)
docker-compose logs envoy | grep '"status":401'
```

### Example Log Analysis

**Question**: What resources did Alice try to access today?

```bash
docker-compose logs envoy | jq 'select(.user == "alice") | {time: .timestamp, path: .path, status: .status}'
```

**Output**:
```json
{"time": "2024-01-20T10:30:45.123Z", "path": "/public", "status": 200}
{"time": "2024-01-20T10:31:22.456Z", "path": "/alice", "status": 200}
{"time": "2024-01-20T10:32:00.789Z", "path": "/bob", "status": 403}
```

**Insight**: Alice successfully accessed public and her own app, but was denied access to Bob's app.

### Production Log Aggregation

In production, logs would typically be sent to:

```yaml
# Example: Send to ELK stack
access_log:
- name: envoy.access_loggers.file
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
    path: /var/log/envoy/access.log
    log_format:
      json_format:
        # Same format as stdout
```

Then ship logs to:
- **Elasticsearch** for indexing and search
- **Splunk** for SIEM and alerting
- **Datadog** for metrics and monitoring
- **CloudWatch** for AWS environments

---

## Security Benefits

### 1. Non-Repudiation

**Traditional logs** (without identity):
```
2024-01-20 10:30:45 GET /alice 200 5ms
```
**Problem**: Who made this request? We don't know!

**Identity-aware logs**:
```json
{"timestamp": "2024-01-20T10:30:45.123Z", "user": "alice", "path": "/alice", "status": 200}
```
**Solution**: Alice accessed this resource. She cannot deny it.

### 2. Audit Trail

Track user actions for:
- **Compliance**: GDPR, HIPAA, SOC2, PCI-DSS
- **Forensics**: Investigate security incidents
- **Analytics**: Understand user behavior patterns
- **Access reviews**: Who accessed what sensitive data

### 3. Incident Response

During a security breach:

```bash
# Find all actions by compromised user
docker-compose logs envoy | jq 'select(.user == "compromised-user")'

# Timeline of access attempts
docker-compose logs envoy | jq 'select(.user == "attacker") | {time: .timestamp, path: .path, status: .status}'

# Identify lateral movement attempts
docker-compose logs envoy | jq 'select(.status == 403 and .response_flags == "RBAC_ACCESS_DENIED")'
```

**Result**: Complete timeline of attacker's actions and attempted actions.

### 4. Anomaly Detection

Monitor for suspicious patterns:
- **Unusual access times**: Alice accessing resources at 3am
- **Rapid failures**: Multiple 403s in short time (brute force?)
- **Privilege escalation**: User trying to access admin resources
- **Data exfiltration**: High volume of successful requests

### 5. Compliance Reporting

Generate reports for auditors:

```bash
# Who accessed patient records today?
cat logs.json | jq 'select(.path == "/patient-records") | {user: .user, time: .timestamp}'

# Failed access attempts to sensitive resources
cat logs.json | jq 'select(.path == "/admin" and .status == 403) | {user: .user, time: .timestamp}'

# All actions by specific user (for access review)
cat logs.json | jq 'select(.user == "john.doe") | {time: .timestamp, resource: .path, result: .status}'
```

### 6. Comparison: VPN vs Reverse Proxy Logging

| Aspect | VPN Logs | Reverse Proxy Logs |
|--------|----------|-------------------|
| **User Identity** | IP address only | Username (from JWT) |
| **Resource** | Network destination | Specific API path |
| **Action** | Network traffic | HTTP method + path |
| **Result** | Connection success/fail | HTTP status + RBAC decision |
| **Context** | No application context | Full request context |
| **Audit Value** | Low (who connected) | High (who did what) |

**VPN Log Example**:
```
2024-01-20 10:30:45 192.168.1.100 connected to 10.0.0.5:3000
```
**Question**: What did they access? Unknown!

**Reverse Proxy Log Example**:
```json
{
  "timestamp": "2024-01-20T10:30:45.123Z",
  "user": "alice",
  "email": "alice@demo.local",
  "method": "GET",
  "path": "/api/patients/12345",
  "status": 200,
  "duration_ms": 45
}
```
**Answer**: Alice viewed patient #12345's record!

---

## Key Takeaways

### How Identity Gets into Logs

1. **JWT Filter** validates token and extracts claims
2. **payload_in_metadata** setting stores claims in dynamic metadata
3. **Metadata namespace**: `envoy.filters.http.jwt_authn`
4. **Metadata key**: `jwt_payload`
5. **Access logger** reads metadata using `%DYNAMIC_METADATA(...)%` format strings
6. **Result**: Every log entry includes user identity

### Benefits

- ✅ **Complete audit trail**: Who accessed what, when, and what happened
- ✅ **Security monitoring**: Detect unauthorized access attempts
- ✅ **Compliance**: Meet regulatory requirements (GDPR, HIPAA, etc.)
- ✅ **Incident response**: Track attacker actions during breaches
- ✅ **Non-repudiation**: Users can't deny their actions
- ✅ **Analytics**: Understand user behavior patterns

### The Critical Configuration

```yaml
# JWT Filter: Store claims in metadata
jwt_authn:
  providers:
    keycloak:
      payload_in_metadata: "jwt_payload"  # ← This line enables identity logging

# Access Logger: Read claims from metadata
access_log:
- name: envoy.access_loggers.stdout
  typed_config:
    log_format:
      json_format:
        user: "%DYNAMIC_METADATA(envoy.filters.http.jwt_authn:jwt_payload:preferred_username)%"
```

**Without `payload_in_metadata`**: No identity in logs (like VPN)
**With `payload_in_metadata`**: Full identity-aware audit trail

---

## Further Reading

- [Envoy Access Logging](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage)
- [Envoy Dynamic Metadata](https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/well_known_dynamic_metadata)
- [JWT Authentication Filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter)
- [Access Log Format Strings](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#format-strings)

---

**Identity-aware access logging transforms security monitoring from "something happened" to "Alice did this at this time to this resource with this result."**
