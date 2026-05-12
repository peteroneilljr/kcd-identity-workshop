# JSON Web Tokens (JWT) Explained

This document provides a comprehensive explanation of JSON Web Tokens (JWT), how they work, and how they're used in our demo for authentication and authorization.

![JWT lifecycle: Keycloak signs the Header.Payload.Signature with its private key; Envoy receives the Bearer JWT, fetches the matching public key from the JWKS endpoint by `kid`, and validates signature, iss/aud, and exp/nbf](JWT-JSON-WEB-TOKEN.svg)

## Table of Contents

1. [What is a JWT?](#what-is-a-jwt)
2. [JWT Structure](#jwt-structure)
3. [How JWTs Work](#how-jwts-work)
4. [JWT in Our Demo](#jwt-in-our-demo)
5. [Security Properties](#security-properties)
6. [Common JWT Claims](#common-jwt-claims)
7. [JWT Validation Process](#jwt-validation-process)
8. [Advantages and Limitations](#advantages-and-limitations)
9. [Best Practices](#best-practices)

---

## What is a JWT?

**JWT (JSON Web Token)** is an open standard (RFC 7519) for securely transmitting information between parties as a JSON object.

### The Problem JWT Solves

**Before JWT** (traditional sessions):
```
User logs in → Server creates session → Stores session in database
Every request → Server looks up session in database
Problem: Stateful, requires database lookup for every request
```

**With JWT**:
```
User logs in → Server creates signed token → Returns token to client
Every request → Server validates signature (no database lookup)
Benefit: Stateless, scalable, no session storage needed
```

### Key Characteristics

- **Self-contained**: Contains all information needed about the user
- **Cryptographically signed**: Cannot be tampered with
- **Compact**: Small enough to send via URL, POST parameter, or HTTP header
- **Stateless**: Server doesn't need to store session data
- **JSON-based**: Easy to parse and use in any programming language

---

## JWT Structure

A JWT consists of three parts separated by dots (`.`):

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwOi8vbG9jYWxob3N0OjgxODAvcmVhbG1zL2RlbW8iLCJzdWIiOiJmMTIzNDU2Ny04OWFiLWNkZWYtMDEyMy00NTY3ODlhYmNkZWYiLCJhdWQiOiJkZW1vLWNsaWVudCIsImV4cCI6MTIzNDU2Nzg5MCwiaWF0IjoxMjM0NTY3NTkwLCJwcmVmZXJyZWRfdXNlcm5hbWUiOiJhbGljZSIsImVtYWlsIjoiYWxpY2VAZGV.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c

Header.Payload.Signature
```

### Visual Breakdown

```
┌─────────────────────────────────────────────────────────┐
│                     Complete JWT                        │
└─────────────────────────────────────────────────────────┘
           │                    │                 │
           ▼                    ▼                 ▼
     ┌─────────┐          ┌─────────┐      ┌──────────┐
     │ Header  │          │ Payload │      │Signature │
     └─────────┘          └─────────┘      └──────────┘
     Base64URL            Base64URL         Binary
     encoded              encoded           (Base64URL
                                            encoded)
```

---

## Part 1: Header

The header typically consists of two parts:
- **alg**: The signing algorithm being used (e.g., RS256, HS256)
- **typ**: The type of token (JWT)

### Example Header (Before Encoding)

```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "abc123"
}
```

### Field Explanations

| Field | Purpose | Example |
|-------|---------|---------|
| `alg` | Algorithm used to sign the token | `RS256` (RSA with SHA-256) |
| `typ` | Type of token | `JWT` |
| `kid` | Key ID - identifies which key was used to sign | `abc123` |

### After Base64URL Encoding

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImFiYzEyMyJ9
```

**Note**: Base64URL encoding makes it URL-safe (uses `-` and `_` instead of `+` and `/`).

---

## Part 2: Payload (Claims)

The payload contains **claims** - statements about the user and additional metadata.

### Example Payload (Before Encoding)

```json
{
  "iss": "http://localhost:8180/realms/demo",
  "sub": "f1234567-89ab-cdef-0123-456789abcdef",
  "aud": "demo-client",
  "exp": 1705759890,
  "iat": 1705759590,
  "nbf": 1705759590,
  "preferred_username": "alice",
  "email": "alice@demo.local",
  "email_verified": true,
  "name": "Alice User",
  "given_name": "Alice",
  "family_name": "User",
  "realm_access": {
    "roles": ["user"]
  },
  "resource_access": {
    "demo-client": {
      "roles": []
    }
  },
  "scope": "openid profile email",
  "session_state": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

### After Base64URL Encoding

```
eyJpc3MiOiJodHRwOi8vbG9jYWxob3N0OjgxODAvcmVhbG1zL2RlbW8iLCJzdWIiOiJmMTIzNDU2Ny04OWFiLWNkZWYtMDEyMy00NTY3ODlhYmNkZWYiLCJhdWQiOiJkZW1vLWNsaWVudCIsImV4cCI6MTcwNTc1OTg5MCwiaWF0IjoxNzA1NzU5NTkwLCJuYmYiOjE3MDU3NTk1OTAsInByZWZlcnJlZF91c2VybmFtZSI6ImFsaWNlIiwiZW1haWwiOiJhbGljZUBkZW1vLmxvY2FsIn0
```

---

## Part 3: Signature

The signature is created by:
1. Taking the encoded header
2. Taking the encoded payload
3. Combining them with a dot
4. Signing with a private key
5. Base64URL encoding the signature

### Signature Creation Process

```
signature = Base64URLEncode(
  sign(
    Base64URLEncode(header) + "." + Base64URLEncode(payload),
    private_key,
    algorithm
  )
)
```

### For RS256 (RSA)

```javascript
// Pseudocode
const data = encodedHeader + "." + encodedPayload;
const signature = RSA_SHA256_Sign(data, privateKey);
const encodedSignature = Base64URLEncode(signature);
```

### Example Signature (Encoded)

```
SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
```

### Why the Signature Matters

The signature ensures:
- ✅ **Integrity**: Token hasn't been modified
- ✅ **Authenticity**: Token was issued by the trusted authority
- ✅ **Non-repudiation**: Issuer can't deny issuing the token

**Critical Security Point**: Only the party with the **private key** can create valid signatures, but anyone with the **public key** can verify them.

---

## How JWTs Work

### The Complete Flow

```
┌──────────────────────────────────────────────┐
│  Step 1: User Authentication                 │
│                                              │
│  User → Keycloak                             │
│  POST /token                                 │
│  username=alice&password=password            │
└───────────────┬──────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────┐
│  Step 2: Keycloak Creates JWT                │
│                                              │
│  1. Validates credentials                    │
│  2. Creates claims (user info)               │
│  3. Creates header (algorithm info)          │
│  4. Signs with private key                   │
│  5. Returns JWT to user                      │
└───────────────┬──────────────────────────────┘
                │
                │ JWT Token
                ▼
┌──────────────────────────────────────────────┐
│  Step 3: User Makes Request                  │
│                                              │
│  User → Envoy                                │
│  GET /alice                                  │
│  Authorization: Bearer <JWT>                 │
└───────────────┬──────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────┐
│  Step 4: Envoy Validates JWT                 │
│                                              │
│  1. Splits JWT into parts                    │
│  2. Decodes header and payload               │
│  3. Fetches public key (JWKS)                │
│  4. Verifies signature                       │
│  5. Checks expiration                        │
│  6. Extracts claims                          │
└───────────────┬──────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────┐
│  Step 5: Authorization Decision              │
│                                              │
│  RBAC checks: username == "alice"?           │
│  Decision: ALLOW or DENY                     │
└──────────────────────────────────────────────┘
```

---

## JWT in Our Demo

### How Keycloak Creates JWTs

When Alice authenticates:

```bash
curl -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "username=alice" \
  -d "password=password" \
  -d "grant_type=password" \
  -d "client_id=demo-client"
```

**Keycloak's Process**:

1. **Validates Credentials**
   ```
   Check: alice / password exists in user database
   Result: ✓ Valid
   ```

2. **Gathers User Information**
   ```json
   {
     "username": "alice",
     "email": "alice@demo.local",
     "roles": ["user"],
     "uuid": "f1234567-89ab-cdef-0123-456789abcdef"
   }
   ```

3. **Creates JWT Claims**
   ```json
   {
     "iss": "http://localhost:8180/realms/demo",
     "sub": "f1234567-89ab-cdef-0123-456789abcdef",
     "preferred_username": "alice",
     "email": "alice@demo.local",
     "realm_access": {"roles": ["user"]},
     "exp": 1705759890,
     "iat": 1705759590
   }
   ```

4. **Creates Header**
   ```json
   {
     "alg": "RS256",
     "typ": "JWT",
     "kid": "abc123"
   }
   ```

5. **Signs the Token**
   ```
   signature = RSA_SHA256(
     base64url(header) + "." + base64url(payload),
     keycloak_private_key
   )
   ```

6. **Returns Complete JWT**
   ```json
   {
     "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJod...",
     "expires_in": 300,
     "token_type": "Bearer"
   }
   ```

### How Envoy Validates JWTs

When request arrives with JWT:

```bash
GET /alice HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
```

**Envoy's Validation Process**:

#### Step 1: Parse JWT

```
Token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRw...
       ↓
Split by '.'
       ↓
Header:    eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9
Payload:   eyJpc3MiOiJodHRwOi8vbG9jYWxob3N0OjgxODAv...
Signature: SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
```

#### Step 2: Decode Header

```json
Base64URLDecode(header) →
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "abc123"
}
```

**Extract**: Algorithm (RS256), Key ID (abc123)

#### Step 3: Fetch Public Key

```bash
# Envoy fetches from JWKS endpoint
GET http://keycloak:8180/realms/demo/protocol/openid-connect/certs

Response:
{
  "keys": [
    {
      "kid": "abc123",
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "n": "xGOr-H7A...",  # Public key modulus
      "e": "AQAB"          # Public key exponent
    }
  ]
}
```

**Envoy caches this** for 5 minutes to avoid repeated requests.

#### Step 4: Verify Signature

```javascript
// Pseudocode
const data = encodedHeader + "." + encodedPayload;
const isValid = RSA_SHA256_Verify(
  data,
  signature,
  publicKey
);

if (!isValid) {
  return 401; // Unauthorized
}
```

**What this proves**:
- ✅ Token was signed by Keycloak (only Keycloak has the private key)
- ✅ Token hasn't been modified (any change breaks the signature)

#### Step 5: Decode and Validate Payload

```json
Base64URLDecode(payload) →
{
  "iss": "http://localhost:8180/realms/demo",
  "sub": "f1234567-89ab-cdef-0123-456789abcdef",
  "aud": "demo-client",
  "exp": 1705759890,
  "iat": 1705759590,
  "preferred_username": "alice"
}
```

**Validations**:
```javascript
// Check issuer
if (claims.iss !== "http://localhost:8180/realms/demo") {
  return 401; // Wrong issuer
}

// Check expiration
if (claims.exp < currentTimestamp) {
  return 401; // Token expired
}

// Check not-before (if present)
if (claims.nbf && claims.nbf > currentTimestamp) {
  return 401; // Token not yet valid
}

// All checks passed
return VALID;
```

#### Step 6: Store in Metadata

```yaml
# Envoy config
jwt_authn:
  payload_in_metadata: "jwt_payload"
```

Stores the decoded payload in dynamic metadata for:
- RBAC filter (authorization decisions)
- Access logger (audit trail)
- Backend apps (user context via header)

---

## Security Properties

### 1. Integrity (Cannot Be Modified)

**Attempt to modify token**:
```
Original token:
Header:  {"alg":"RS256","typ":"JWT"}
Payload: {"preferred_username":"alice","roles":["user"]}

Attacker modifies payload:
Payload: {"preferred_username":"alice","roles":["user","admin"]}
         ↓
New Token: header.modified_payload.original_signature
         ↓
Verification: FAILS!
```

**Why?** Signature was computed over original payload. Any change breaks the signature.

### 2. Authenticity (Issued by Trusted Authority)

**Only Keycloak can create valid tokens**:
```
Keycloak has: Private Key (secret, never shared)
Everyone has: Public Key (openly available)

Signing:    Private Key → Create signature
Verifying:  Public Key  → Verify signature

Result: Only Keycloak can sign, but anyone can verify
```

### 3. Stateless Validation (No Database Lookup)

**Traditional Session**:
```
Request → Server checks session database → Slow, not scalable
```

**JWT**:
```
Request → Server verifies signature → Fast, scalable
No database lookup required!
```

### 4. Expiration (Limited Lifetime)

Every JWT has an `exp` claim:
```json
{
  "exp": 1705759890  // Unix timestamp
}
```

**After expiration**:
```
Current time: 1705759900
Token exp:    1705759890
Result: Token is expired → 401 Unauthorized
```

**Security benefit**: Stolen tokens have limited usefulness.

---

## Common JWT Claims

### Standard Claims (RFC 7519)

| Claim | Name | Type | Purpose | Example |
|-------|------|------|---------|---------|
| `iss` | Issuer | String | Who created the token | `http://localhost:8180/realms/demo` |
| `sub` | Subject | String | Who the token is about (user ID) | `f1234567-89ab-cdef-0123-456789abcdef` |
| `aud` | Audience | String/Array | Who can use the token | `demo-client` |
| `exp` | Expiration Time | Number | When token expires (Unix timestamp) | `1705759890` |
| `iat` | Issued At | Number | When token was created | `1705759590` |
| `nbf` | Not Before | Number | Token not valid before this time | `1705759590` |
| `jti` | JWT ID | String | Unique identifier for this token | `a1b2c3d4-e5f6` |

### OpenID Connect Claims

| Claim | Purpose | Example |
|-------|---------|---------|
| `preferred_username` | Username for display | `alice` |
| `email` | Email address | `alice@demo.local` |
| `email_verified` | Email verification status | `true` |
| `name` | Full name | `Alice User` |
| `given_name` | First name | `Alice` |
| `family_name` | Last name | `User` |
| `picture` | Profile picture URL | `https://...` |

### Custom Claims (Keycloak-Specific)

| Claim | Purpose | Example |
|-------|---------|---------|
| `realm_access.roles` | Realm-level roles | `["user"]` |
| `resource_access` | Client-specific roles | `{"demo-client": {"roles": []}}` |
| `session_state` | Session identifier | `a1b2c3d4-e5f6-7890-abcd` |
| `scope` | OAuth2 scopes granted | `openid profile email` |

---

## JWT Validation Process

### Complete Validation Checklist

Envoy performs these checks in order:

```
┌────────────────────────────────────────────┐
│ 1. Token Format Check                     │
│    ✓ Has three parts (header.payload.sig) │
│    ✓ Valid Base64URL encoding             │
└────────────────┬───────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────┐
│ 2. Header Validation                       │
│    ✓ Can decode header                     │
│    ✓ Algorithm is allowed (RS256)         │
│    ✓ Key ID (kid) is present              │
└────────────────┬───────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────┐
│ 3. Fetch Public Key                        │
│    ✓ Find key with matching kid            │
│    ✓ Key is for signature verification     │
└────────────────┬───────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────┐
│ 4. Signature Verification                  │
│    ✓ Recompute expected signature          │
│    ✓ Compare with token signature          │
│    ✓ Signatures match                      │
└────────────────┬───────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────┐
│ 5. Claims Validation                       │
│    ✓ Issuer (iss) matches expected         │
│    ✓ Expiration (exp) in future            │
│    ✓ Not-before (nbf) in past              │
│    ✓ Audience (aud) matches (if checked)   │
└────────────────┬───────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────┐
│ 6. Extract Claims                          │
│    ✓ Store in metadata                     │
│    ✓ Available for authorization           │
└────────────────────────────────────────────┘
```

### What Happens on Failure?

| Check | Failure Result | HTTP Status | Why |
|-------|---------------|-------------|-----|
| Format | "Jwt is missing" | 401 | Token not in Authorization header |
| Signature | "Jwt verification fails" | 401 | Token tampered or wrong issuer |
| Expiration | "Jwt is expired" | 401 | Token TTL exceeded |
| Issuer | "Jwt issuer is not configured" | 401 | Token from wrong issuer |

---

## Advantages and Limitations

### Advantages

✅ **Stateless**
- Server doesn't store session data
- Horizontally scalable (no shared session store)
- Works across distributed systems

✅ **Self-Contained**
- All user information in the token
- No database lookup needed for each request
- Reduces latency

✅ **Cross-Domain**
- Works across different domains
- Enables microservices architecture
- Single sign-on (SSO) capabilities

✅ **Compact**
- Small enough for HTTP headers
- Can be sent via URL parameters
- Mobile-friendly

✅ **JSON-Based**
- Easy to parse in any language
- Human-readable (when decoded)
- Extensible with custom claims

### Limitations

❌ **Cannot Be Revoked**
- Once issued, valid until expiration
- Logout doesn't invalidate token
- **Mitigation**: Short expiration + refresh tokens

❌ **Size**
- Larger than session IDs
- Sent with every request (bandwidth)
- **Mitigation**: Keep claims minimal

❌ **Secrets in Token**
- Don't put sensitive data in payload
- Payload is only Base64-encoded, not encrypted
- **Mitigation**: Use encryption if needed (JWE)

❌ **Replay Attacks**
- Stolen token can be used until expiration
- **Mitigation**: Short TTL, HTTPS, secure storage

---

## Best Practices

### Security Best Practices

#### 1. Use Strong Algorithms

```yaml
# Good: RS256 (RSA with SHA-256)
jwt_authn:
  providers:
    keycloak:
      issuer: "..."
      # RS256 by default from JWKS

# Bad: HS256 with shared secret (if secret leaks, anyone can create tokens)
```

#### 2. Short Expiration Times

```json
{
  "exp": 1705759890,  // 5 minutes from issuance
  "iat": 1705759590
}
```

**Recommendation**: 5-15 minutes for access tokens, use refresh tokens for longer sessions.

#### 3. Always Validate

```javascript
// ✓ ALWAYS check
- Signature
- Expiration (exp)
- Not-before (nbf)
- Issuer (iss)
- Audience (aud)

// ✗ NEVER skip validation
// ✗ NEVER trust token without verifying signature
```

#### 4. Use HTTPS

```
❌ HTTP:  Token visible in network traffic
✅ HTTPS: Token encrypted in transit
```

#### 5. Secure Storage

**Client-side storage**:
```
❌ localStorage: Vulnerable to XSS
❌ sessionStorage: Vulnerable to XSS
✅ HttpOnly cookies: Protected from JavaScript access
✅ Memory only (for SPAs): Lost on refresh but more secure
```

#### 6. Implement Refresh Tokens

```
Access Token:  Short-lived (5 min), sent with every request
Refresh Token: Long-lived (1 hour), used only to get new access tokens

When access token expires:
  Use refresh token to get new access token
  Never send refresh token with API requests
```

#### 7. Don't Put Secrets in JWT

```json
// ❌ BAD: Sensitive data in token
{
  "username": "alice",
  "ssn": "123-45-6789",
  "credit_card": "4111-1111-1111-1111"
}

// ✅ GOOD: Only identifiers and permissions
{
  "sub": "f1234567-89ab-cdef-0123-456789abcdef",
  "username": "alice",
  "roles": ["user"]
}
```

**Remember**: JWT payload is only encoded, not encrypted!

### Operational Best Practices

#### 1. Key Rotation

```
Regular rotation of signing keys (every 3-6 months):
- Generate new key pair
- Add new key to JWKS with new kid
- Keep old key for validation (grace period)
- After grace period, remove old key
```

#### 2. Monitoring

```bash
# Monitor for:
- High rate of 401 errors (attack?)
- Expired tokens (clock skew?)
- Invalid signatures (tampering attempts?)
- Unusual claims (modified tokens?)
```

#### 3. Logging

```json
// Log validation failures
{
  "timestamp": "2024-01-20T10:30:45Z",
  "event": "jwt_validation_failed",
  "reason": "signature_invalid",
  "issuer": "unknown",
  "client_ip": "192.168.1.100"
}
```

---

## Decoding JWTs (For Learning)

### Using Command Line

```bash
# Get token
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "username=alice&password=password&grant_type=password&client_id=demo-client" \
  | jq -r '.access_token')

# Decode header
echo $TOKEN | cut -d'.' -f1 | base64 -d 2>/dev/null | jq '.'

# Decode payload
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.'

# Note: Signature is binary, can't decode to JSON
```

### Using Online Tools (Development Only!)

⚠️ **WARNING**: Never paste production JWTs into online tools!

For learning/development:
- [jwt.io](https://jwt.io) - Decode and verify JWTs
- [jwt.ms](https://jwt.ms) - Microsoft's JWT decoder

**For production**: Use libraries in your programming language.

---

## Summary

### What is a JWT?

A **cryptographically signed**, **self-contained** token that proves:
- **Who you are** (claims about identity)
- **What you can do** (permissions/roles)
- **When it expires** (time-limited)

### How It Works in Our Demo

1. **Keycloak creates JWT** with user identity and signs it
2. **Client sends JWT** with every request (Authorization header)
3. **Envoy validates JWT** signature and checks expiration
4. **Envoy extracts claims** for authorization decisions
5. **Access logs include identity** from JWT claims

### Key Security Properties

- ✅ **Integrity**: Cannot be modified without detection
- ✅ **Authenticity**: Only Keycloak can create valid tokens
- ✅ **Stateless**: No server-side session storage needed
- ✅ **Time-limited**: Automatic expiration reduces risk
- ✅ **Auditable**: Identity available for logging

### The Trade-off

**Benefit**: Stateless, scalable, no session storage
**Cost**: Cannot revoke before expiration

**Solution**: Use short expiration times (5-15 minutes) + refresh tokens for longer sessions.

---

## Further Reading

- [RFC 7519 - JSON Web Token (JWT)](https://tools.ietf.org/html/rfc7519)
- [JWT.io Introduction](https://jwt.io/introduction)
- [OWASP JWT Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
- [RFC 7515 - JSON Web Signature (JWS)](https://tools.ietf.org/html/rfc7515)
- [RFC 7516 - JSON Web Encryption (JWE)](https://tools.ietf.org/html/rfc7516)
- [RFC 7517 - JSON Web Key (JWK)](https://tools.ietf.org/html/rfc7517)

---

**Understanding JWTs is fundamental to modern authentication. They enable stateless, scalable, and secure identity management across distributed systems.**
