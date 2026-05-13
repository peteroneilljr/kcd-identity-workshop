# OAuth2 and OpenID Connect (OIDC) Explained

This document explains how OAuth2 and OpenID Connect work in our demo and why both protocols are essential for modern authentication and authorization.

![Sequence diagram with five lifelines — Resource Owner, Client, Keycloak, Envoy, Backend — showing the eight numbered messages of the OAuth2/OIDC flow: credentials → POST /token → JWT + refresh → Authorization: Bearer → JWKS lookup → public key → forward → response](../assets/OAUTH-OIDC.svg)

## Table of Contents

1. [OAuth2 vs OIDC: The Relationship](#oauth2-vs-oidc-the-relationship)
2. [OAuth2 Fundamentals](#oauth2-fundamentals)
3. [OpenID Connect (OIDC) Layer](#openid-connect-oidc-layer)
4. [How Our Demo Uses OAuth2 + OIDC](#how-our-demo-uses-oauth2--oidc)
5. [Production OAuth2 Flow](#production-oauth2-flow-authorization-code)
6. [Key OIDC Endpoints](#key-oidc-endpoints-in-keycloak)
7. [Summary](#summary)

---

## OAuth2 vs OIDC: The Relationship

```
┌─────────────────────────────────────┐
│         OpenID Connect              │  ← Identity Layer (Who are you?)
│       (Authentication)              │
├─────────────────────────────────────┤
│           OAuth 2.0                 │  ← Authorization Framework
│      (What can you access?)         │
└─────────────────────────────────────┘
```

**Key Concept**: OpenID Connect (OIDC) is built **on top of** OAuth2.

- **OAuth2** handles **authorization** (what you can access)
- **OIDC** adds **authentication** (who you are)

### The Analogy

- **OAuth2**: Like a valet key for your car - gives limited access but doesn't identify you
- **OIDC**: Like your driver's license - proves your identity AND gives you permission to drive

---

## OAuth2 Fundamentals

### What Problem Does OAuth2 Solve?

**Without OAuth2** (the old, insecure way):
```
User → gives username/password to every app
     → App stores your credentials
     → App uses your credentials directly
     → PROBLEM: Every app has your password!
```

**With OAuth2** (the modern way):
```
User → authenticates once with identity provider
     → Gets a token
     → Apps use token (not password)
     → Apps never see your password
     → Token can be revoked
```

### OAuth2 Components in Our Demo

```
┌─────────────────────────────────────────────┐
│  Resource Owner (User)                      │
│  - Alice or Bob                             │
│  - Wants to access protected resources      │
└──────────────┬──────────────────────────────┘
               │ 1. "I want to login"
               ▼
┌─────────────────────────────────────────────┐
│  Authorization Server (Keycloak)            │
│  - Authenticates users                      │
│  - Issues access tokens                     │
│  - Port: 8180                               │
└──────────────┬──────────────────────────────┘
               │ 2. Returns access token (JWT)
               ▼
┌─────────────────────────────────────────────┐
│  Client (curl in our demo)                  │
│  - Requests resources with token            │
│  - In production: web app, mobile app       │
└──────────────┬──────────────────────────────┘
               │ 3. Request with Bearer token
               ▼
┌─────────────────────────────────────────────┐
│  Resource Server (Envoy + backend apps)     │
│  - Validates token                          │
│  - Returns protected resource               │
│  - Port: 8080                               │
└─────────────────────────────────────────────┘
```

### OAuth2 Grant Type: Password Grant (Demo Only!)

Our demo uses **Resource Owner Password Credentials Grant**:

```bash
curl -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "username=alice" \
  -d "password=password" \
  -d "grant_type=password" \        # ← OAuth2 grant type
  -d "client_id=demo-client"
```

#### Why This Grant Type?

**Advantages for demos**:
- ✅ Simple (direct username/password)
- ✅ No browser redirect needed
- ✅ Good for CLI tools and testing
- ✅ Easy to demonstrate in presentations

**Why NOT in production**:
- ❌ Client sees user password
- ❌ No multi-factor authentication support
- ❌ Can't use federated identity (Google, Microsoft)
- ❌ Violates OAuth2 security best practices
- ❌ Can't delegate without sharing credentials

**Production alternative**: Authorization Code Flow with PKCE (see below)

---

## OpenID Connect (OIDC) Layer

### What OIDC Adds to OAuth2

OAuth2 alone only provides **access tokens** (authorization). OIDC adds **identity information** (authentication).

#### OAuth2 Token Response (Basic):
```json
{
  "access_token": "opaque-string-abc123",
  "token_type": "Bearer",
  "expires_in": 300
}
```
**Problem**: No identity information! Who is this user?

#### OIDC Token Response (Enhanced):
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 300,
  "id_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refresh_token": "...",
  "scope": "openid profile email"
}
```
**Solution**: Now we know username, email, roles, and more!

### OIDC Discovery Endpoint

Keycloak exposes OIDC metadata at a standard location:

```bash
curl http://localhost:8180/realms/demo/.well-known/openid-configuration | jq '.'
```

**Returns**:
```json
{
  "issuer": "http://localhost:8180/realms/demo",
  "authorization_endpoint": "http://localhost:8180/realms/demo/protocol/openid-connect/auth",
  "token_endpoint": "http://localhost:8180/realms/demo/protocol/openid-connect/token",
  "userinfo_endpoint": "http://localhost:8180/realms/demo/protocol/openid-connect/userinfo",
  "jwks_uri": "http://localhost:8180/realms/demo/protocol/openid-connect/certs",
  "grant_types_supported": ["authorization_code", "password", "refresh_token"],
  "response_types_supported": ["code", "token", "id_token"],
  "scopes_supported": ["openid", "profile", "email", "roles"],
  "claims_supported": ["sub", "email", "preferred_username", "name"],
  "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]
}
```

**This tells clients**:
- ✅ Where to get tokens
- ✅ What grant types are supported
- ✅ What user claims are available
- ✅ Where to get public keys for validation
- ✅ What authentication methods are supported

### OIDC Scopes

OIDC defines standard scopes for requesting user information:

```bash
# Request with OIDC scopes
curl -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "username=alice" \
  -d "password=password" \
  -d "grant_type=password" \
  -d "client_id=demo-client" \
  -d "scope=openid profile email"  # ← OIDC scopes
```

#### Standard OIDC Scopes

| Scope | Claims Included | Purpose |
|-------|----------------|---------|
| `openid` | `sub` (subject/user ID) | **Required** for OIDC |
| `profile` | `name`, `given_name`, `family_name`, `nickname`, `picture`, `website`, etc. | User profile information |
| `email` | `email`, `email_verified` | Email address |
| `address` | `address` (JSON object) | Physical mailing address |
| `phone` | `phone_number`, `phone_number_verified` | Phone number |

**In our demo**: The `openid` scope is implicitly included, which gives us `sub` and `preferred_username` claims.

---

## How Our Demo Uses OAuth2 + OIDC

### Step-by-Step Flow

#### Step 1: Token Request (OAuth2 + OIDC)

```bash
POST http://localhost:8180/realms/demo/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

username=alice&
password=password&
grant_type=password&          # OAuth2 parameter
client_id=demo-client&        # OAuth2 parameter
scope=openid profile email    # OIDC parameter (implicit in our demo)
```

**What happens inside Keycloak**:
1. ✅ Validates username/password against user database
2. ✅ Generates JWT access token with OIDC claims
3. ✅ Signs token with private key (RS256 algorithm)
4. ✅ Returns token to client

#### Step 2: Token Response (OIDC Format)

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwOi8v...",
  "expires_in": 300,
  "refresh_expires_in": 1800,
  "refresh_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "not-before-policy": 0,
  "session_state": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "scope": "openid profile email"
}
```

#### Step 3: JWT Token Structure

The `access_token` is a JWT (JSON Web Token) with three parts:

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9    ← Header (base64)
.
eyJpc3MiOiJodHRwOi8vbG9jYWxob3N0...    ← Payload (base64)
.
SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV... ← Signature (binary)
```

**Decoded Header**:
```json
{
  "alg": "RS256",           // Algorithm: RSA with SHA-256
  "typ": "JWT",             // Type: JSON Web Token
  "kid": "abc123"           // Key ID (identifies which key was used)
}
```

**Decoded Payload** (OIDC claims):
```json
{
  // OIDC Standard Claims
  "iss": "http://localhost:8180/realms/demo",  // Issuer
  "sub": "f1234567-89ab-cdef-0123-456789abcdef", // Subject (unique user ID)
  "aud": "demo-client",     // Audience (who can use this token)
  "exp": 1234567890,        // Expiration time (Unix timestamp)
  "iat": 1234567590,        // Issued at time
  "nbf": 1234567590,        // Not before time

  // OIDC Profile Claims
  "preferred_username": "alice",  // ← Used in our RBAC policies!
  "email": "alice@demo.local",
  "email_verified": true,
  "name": "Alice User",
  "given_name": "Alice",
  "family_name": "User",

  // Custom/Realm-Specific Claims
  "realm_access": {
    "roles": ["user"]       // ← Also available for authorization
  },
  "resource_access": {
    "demo-client": {
      "roles": []
    }
  },

  // OIDC Session Claims
  "session_state": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "scope": "openid profile email",
  "typ": "Bearer"
}
```

**Signature**: Cryptographic signature that proves:
- ✅ Token was issued by Keycloak (not forged)
- ✅ Token hasn't been tampered with
- ✅ Token is authentic

#### Step 4: Using the Token (OAuth2 Bearer Token)

```bash
GET http://localhost:8080/alice
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
```

**This is OAuth2 "Bearer Token" authentication**:
- Token is "bearer" - whoever has it can use it (like cash)
- Sent in `Authorization` header
- Format: `Bearer <token>`
- No additional proof of possession required

#### Step 5: Token Validation (OIDC JWT Validation)

**Envoy performs OIDC-compliant JWT validation**:

```yaml
# envoy.yaml
jwt_authn:
  providers:
    keycloak:
      issuer: "http://localhost:8180/realms/demo"  # ← OIDC issuer claim
      remote_jwks:
        http_uri:
          uri: "http://keycloak:8180/realms/demo/protocol/openid-connect/certs"
          # ↑ OIDC JWKS (JSON Web Key Set) endpoint
        cache_duration:
          seconds: 300    # Cache keys for 5 minutes
      payload_in_metadata: "jwt_payload"  # Store claims in metadata
```

**Validation steps** (OIDC standard process):

1. **Extract JWT** from `Authorization: Bearer <token>` header
2. **Parse JWT** into header, payload, and signature
3. **Fetch public key** from JWKS endpoint (cached for performance)
4. **Verify signature** using RS256 algorithm and public key
5. **Check issuer** (`iss` claim must match expected issuer)
6. **Check expiration** (`exp` claim must be in the future)
7. **Check not-before** (`nbf` claim must be in the past)
8. **Check audience** (`aud` claim matches, if configured)
9. **Extract claims** from payload for authorization decisions

**If any check fails → 401 Unauthorized**

#### Step 6: Authorization Using OIDC Claims

```yaml
# envoy.yaml RBAC policy
"allow-alice-only":
  permissions:
  - header:
      name: ":path"
      string_match:
        prefix: "/alice"
  principals:
  - metadata:
      filter: "envoy.filters.http.jwt_authn"
      path:
      - key: "jwt_payload"              # ← JWT payload from OIDC token
      - key: "preferred_username"       # ← OIDC standard claim
      value:
        string_match:
          exact: "alice"
```

**This uses OIDC claims for authorization!**

- ✅ Extract `preferred_username` from validated JWT
- ✅ Compare to expected value ("alice")
- ✅ Allow if match, deny (403) if mismatch

---

## Visualizing the Complete Flow

```
┌──────────┐
│  Alice   │
└────┬─────┘
     │ 1. POST /token (OAuth2 + OIDC)
     │    Content-Type: application/x-www-form-urlencoded
     │    username=alice
     │    password=password
     │    grant_type=password
     │    client_id=demo-client
     │    scope=openid profile email
     ▼
┌─────────────────────────────────────┐
│          Keycloak                   │
│  (OAuth2 Authorization Server +     │
│   OIDC Identity Provider)           │
│                                     │
│  Process:                           │
│  ✓ Validates credentials            │
│  ✓ Generates JWT                    │
│  ✓ Adds OIDC standard claims:       │
│    - iss, sub, aud, exp, iat        │
│    - preferred_username, email      │
│  ✓ Adds custom claims (roles)       │
│  ✓ Signs with RS256 private key     │
└────┬────────────────────────────────┘
     │ 2. Returns OAuth2/OIDC token response
     │    {
     │      "access_token": "eyJhbG...",  ← JWT with OIDC claims
     │      "token_type": "Bearer",       ← OAuth2 token type
     │      "expires_in": 300,
     │      "refresh_token": "...",
     │      "scope": "openid profile email"
     │    }
     ▼
┌──────────┐
│  Alice   │ (now has JWT access token)
└────┬─────┘
     │ 3. GET /alice
     │    Authorization: Bearer eyJhbG...  ← OAuth2 Bearer Token
     ▼
┌─────────────────────────────────────┐
│            Envoy Proxy              │
│  (OAuth2 Resource Server +          │
│   OIDC Token Validator)             │
│                                     │
│  JWT Authentication Filter:         │
│  ✓ Extracts Bearer token            │ ← OAuth2
│  ✓ Fetches JWKS from Keycloak       │ ← OIDC
│  ✓ Verifies JWT signature           │ ← OIDC JWT
│  ✓ Checks issuer (iss)              │ ← OIDC
│  ✓ Checks expiration (exp)          │ ← OIDC JWT
│  ✓ Checks audience (aud)            │ ← OIDC
│  ✓ Extracts claims to metadata      │ ← OIDC
│                                     │
│  RBAC Authorization Filter:         │
│  ✓ Reads preferred_username         │ ← OIDC claim
│  ✓ Checks if "alice"                │ ← Custom authz
│  ✓ Matches path "/alice"            │ ← Custom authz
│  ✓ Decision: ALLOW                  │
└────┬────────────────────────────────┘
     │ 4. Forwards request to alice-app
     │    (with x-jwt-payload header)
     ▼
┌─────────────────────────────────────┐
│          alice-app                  │
│  (Protected Resource)               │
│                                     │
│  ✓ Trusts Envoy's validation        │
│  ✓ Can read user info from header   │
│  ✓ Returns Alice-specific content   │
└─────────────────────────────────────┘
```

---

## Production OAuth2 Flow (Authorization Code)

**Our demo uses password grant for simplicity. Production systems should use Authorization Code Flow with PKCE.**

### Authorization Code Flow (The Right Way)

```
1. User → Clicks "Login" in Your App
   └─→ https://yourapp.com/login

2. Your App → Redirects to Keycloak
   └─→ https://keycloak.com/auth?
       response_type=code&
       client_id=your-app&
       redirect_uri=https://yourapp.com/callback&
       scope=openid profile email&
       state=random-string&              ← CSRF protection
       code_challenge=sha256(verifier)&  ← PKCE
       code_challenge_method=S256

3. User → Sees Keycloak login page
   └─→ Enters username/password
       (Keycloak sees credentials, NOT your app!)

4. User → Authenticates (MFA if enabled)

5. Keycloak → Redirects back with authorization code
   └─→ https://yourapp.com/callback?
       code=AUTH_CODE_abc123&            ← One-time use code
       state=random-string               ← Must match request

6. Your App → Exchanges code for token (backend)
   POST https://keycloak.com/token
   Content-Type: application/x-www-form-urlencoded

   code=AUTH_CODE_abc123&
   grant_type=authorization_code&
   client_id=your-app&
   client_secret=secret&                 ← Server-side only
   redirect_uri=https://yourapp.com/callback&
   code_verifier=original-random-string  ← PKCE verifier

7. Keycloak → Returns tokens
   {
     "access_token": "eyJhbG...",        ← For API access
     "id_token": "eyJhbG...",            ← User identity (OIDC)
     "refresh_token": "...",             ← For token renewal
     "token_type": "Bearer",
     "expires_in": 300,
     "scope": "openid profile email"
   }

8. Your App → Uses access_token for API calls
   Authorization: Bearer eyJhbG...

9. API (Envoy) → Validates token
   └─→ Same validation as our demo

10. When token expires → Use refresh_token
    POST https://keycloak.com/token
    grant_type=refresh_token&
    refresh_token=...&
    client_id=your-app&
    client_secret=secret
```

### Why Authorization Code Flow?

**Security Benefits**:
- ✅ Your app **never sees** user password
- ✅ Supports **MFA** (multi-factor authentication)
- ✅ Supports **federated identity** (Google, Microsoft, etc.)
- ✅ Code can only be used **once**
- ✅ Code is short-lived (30-60 seconds)
- ✅ PKCE prevents **code interception attacks**
- ✅ Refresh tokens for **long-lived sessions**
- ✅ State parameter prevents **CSRF attacks**

**Production Best Practices**:
- Use PKCE (Proof Key for Code Exchange) for mobile/SPA
- Use confidential clients with client secrets
- Store tokens securely (never in localStorage for sensitive apps)
- Use refresh tokens with rotation
- Implement proper session management

---

## Key OIDC Endpoints in Keycloak

### 1. Discovery Endpoint (Well-Known Configuration)

```bash
curl http://localhost:8180/realms/demo/.well-known/openid-configuration | jq '.'
```

**Purpose**: Tells clients everything about the OIDC provider

### 2. Authorization Endpoint (Browser Redirect)

```
http://localhost:8180/realms/demo/protocol/openid-connect/auth
```

**Purpose**: Where users are redirected to login (Authorization Code Flow)

**Example**:
```
http://localhost:8180/realms/demo/protocol/openid-connect/auth?
  response_type=code&
  client_id=demo-client&
  redirect_uri=http://localhost:3000/callback&
  scope=openid profile email
```

### 3. Token Endpoint (Exchange Code/Password for Token)

```
http://localhost:8180/realms/demo/protocol/openid-connect/token
```

**Purpose**: Exchange authorization code (or password) for access token

**Used in our demo**:
```bash
curl -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "username=alice&password=password&grant_type=password&client_id=demo-client"
```

### 4. UserInfo Endpoint (Get User Details)

```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://localhost:8180/realms/demo/protocol/openid-connect/userinfo
```

**Returns**:
```json
{
  "sub": "f1234567-89ab-cdef-0123-456789abcdef",
  "preferred_username": "alice",
  "email": "alice@demo.local",
  "email_verified": true,
  "name": "Alice User"
}
```

**Purpose**: Fetch additional user information using access token

### 5. JWKS Endpoint (Public Keys)

```bash
curl http://localhost:8180/realms/demo/protocol/openid-connect/certs | jq '.'
```

**Returns**:
```json
{
  "keys": [
    {
      "kid": "abc123",
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "n": "xGOr-H7A...",  // Public key modulus
      "e": "AQAB"          // Public key exponent
    }
  ]
}
```

**Purpose**: Public keys for verifying JWT signatures (Envoy uses this!)

### 6. Logout Endpoint

```
http://localhost:8180/realms/demo/protocol/openid-connect/logout
```

**Purpose**: End user session

**Example**:
```
http://localhost:8180/realms/demo/protocol/openid-connect/logout?
  redirect_uri=http://localhost:3000/
```

---

## Summary: OAuth2 + OIDC in This Demo

### Component Roles

| Component | OAuth2 Role | OIDC Role | Implementation |
|-----------|-------------|-----------|----------------|
| **Keycloak** | Authorization Server | Identity Provider | Issues JWT with OIDC claims |
| **Envoy** | Resource Server | Token Validator | Validates JWT via JWKS |
| **Backend Apps** | Protected Resources | - | Trust Envoy's validation |
| **JWT Token** | Access Token | ID Token | Contains identity claims |
| **Bearer Token** | OAuth2 Standard | - | Token in Authorization header |

### OAuth2 Elements Used

- ✅ **Authorization Server**: Keycloak issues tokens
- ✅ **Resource Server**: Envoy + backend apps validate tokens
- ✅ **Access Token**: JWT token grants access to resources
- ✅ **Bearer Token**: Token sent in `Authorization: Bearer` header
- ✅ **Grant Type**: Password grant (demo only, not for production)
- ✅ **Token Endpoint**: `/realms/demo/protocol/openid-connect/token`
- ✅ **Token Expiration**: 5-minute TTL (exp claim)

### OIDC Elements Used

- ✅ **Identity Provider**: Keycloak provides user identity
- ✅ **ID Token**: JWT contains user claims (identity)
- ✅ **UserInfo Endpoint**: Can fetch additional user details
- ✅ **Standard Claims**: `sub`, `iss`, `aud`, `exp`, `preferred_username`, `email`
- ✅ **Discovery**: `.well-known/openid-configuration` endpoint
- ✅ **JWKS Endpoint**: Public keys for JWT verification
- ✅ **Scopes**: `openid profile email` (implicit)

### The Magic

**OAuth2** provides the authorization framework
**OIDC** provides the user identity
**RBAC policies** use OIDC identity claims for access decisions

**Result**: Per-user, identity-aware, zero-trust authorization!

---

## Try It Yourself

### View OIDC Discovery

```bash
curl -s http://localhost:8180/realms/demo/.well-known/openid-configuration | jq '.'
```

### Get a Token

```bash
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "username=alice&password=password&grant_type=password&client_id=demo-client" \
  | jq -r '.access_token')
```

### Decode the JWT

```bash
# Header
echo $TOKEN | cut -d'.' -f1 | base64 -d 2>/dev/null | jq '.'

# Payload (OIDC claims)
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.'
```

### View JWKS (Public Keys)

```bash
curl -s http://localhost:8180/realms/demo/protocol/openid-connect/certs | jq '.'
```

### Get UserInfo

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8180/realms/demo/protocol/openid-connect/userinfo | jq '.'
```

---

## Further Reading

- [OAuth 2.0 RFC 6749](https://tools.ietf.org/html/rfc6749) - Official OAuth2 specification
- [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html) - Official OIDC specification
- [JWT RFC 7519](https://tools.ietf.org/html/rfc7519) - JSON Web Token specification
- [OAuth 2.0 Security Best Practices](https://tools.ietf.org/html/draft-ietf-oauth-security-topics)
- [PKCE RFC 7636](https://tools.ietf.org/html/rfc7636) - Proof Key for Code Exchange
- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Envoy JWT Authentication](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter)

---

**Understanding OAuth2 and OIDC is crucial for modern authentication and authorization. This demo shows these protocols in action!**
