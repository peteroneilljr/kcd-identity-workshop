# Identity Bridging: One Login, Many Systems

This document explains the meta-pattern that ties the entire workshop together. Each backend in this demo (HTTP, Postgres, Grafana, SSH) integrates Keycloak identity in a different way — but the *shape* of every integration is the same. Understanding that shape lets you apply the pattern to any system you'd care to add: AWS, kubectl, Vault, Slack, Snowflake, GraphQL, gRPC, S3, your own internal service.

## Table of Contents

1. [The shape of every integration](#the-shape-of-every-integration)
2. [Why one IdP isn't enough by itself](#why-one-idp-isnt-enough-by-itself)
3. [The four integration patterns in this demo](#the-four-integration-patterns-in-this-demo)
4. [Generalizing: where else this pattern shows up](#generalizing-where-else-this-pattern-shows-up)
5. [Choosing a pattern for a new backend](#choosing-a-pattern-for-a-new-backend)
6. [Anti-patterns](#anti-patterns)
7. [Production hardening checklist](#production-hardening-checklist)

---

## The shape of every integration

Strip away the protocol-specific details and every identity-aware backend integration in this workshop has the same five-step structure:

```
1. Authenticate to the IdP once         →  primary credential (Keycloak password)
                ▼
2. Receive a short-lived assertion      →  JWT (RS256-signed)
                ▼
3. Either:                                  ┌────────────────────────────────────┐
   (a) present the JWT directly to a        │ Backend understands the assertion │
       backend that verifies it,            │ (HTTP w/ JWT-aware proxy)         │
       OR                                   ├────────────────────────────────────┤
   (b) exchange the JWT for a credential    │ Backend doesn't speak JWT;        │
       the backend's native auth accepts    │ a bridge service exchanges JWT    │
                                            │ for the protocol's native auth     │
                                            │ token (DB role, SSH cert, etc.)   │
                                            └────────────────────────────────────┘
                ▼
4. Use the resulting credential
                ▼
5. Credential expires quickly; refresh as needed
```

Step 3 is where the design choices happen. The system either *natively* understands the JWT (Grafana via OIDC, HTTP services via Envoy's JWT filter), or it *doesn't*, and a small bridge service stands between the JWT and the protocol-native credential (db-app converts JWT → SQL role assumption; ssh-ca converts JWT → SSH cert).

What makes this work — what makes it identity-aware rather than just authenticated — is that **the JWT identity propagates through every layer**. The DB role is alice's, the SSH cert's principal is alice's, the Grafana session belongs to alice. Every system enforces *what alice in particular* can do, not what some generic service account can do.

## Why one IdP isn't enough by itself

A common mistake is to think "we use Keycloak/Okta/Azure AD as our IdP, so we have identity-aware access." That gets you authentication. It doesn't get you authorization at the resource level.

Three properties have to be true for end-to-end identity-aware access:

1. **The user's identity is verifiable** at the resource. Either the resource consumes the JWT directly, or a trusted intermediary attests to it.
2. **The resource's authorization model honors the upstream identity.** The DB filters rows by current_user; the file system maps cert principals to unix users; the dashboard maps OIDC claims to internal roles.
3. **The credential at the resource is short-lived.** Otherwise step 2 becomes vacuous — a 1-year-valid DB password can't be tied to "the person currently authenticated to Keycloak."

A SAML/OIDC IdP gives you (1) at the front door. The rest of the system has to give you (2) and (3) at every backend, separately. That's the work this workshop demonstrates: not the IdP setup, but the wiring at every other layer.

## The four integration patterns in this demo

### Pattern A: bearer-token gateway (HTTP services)

```
JWT  ─────►  Envoy  ─────►  backend
          (verifies,
           applies RBAC,
           forwards claims)
```

The most direct shape. The proxy validates the JWT for the backend, applies its own coarse authorization (RBAC by username), and forwards the verified claims so the backend can do its own fine-grained checks if it wants to. Backends never have to know about JWTs.

**Suits:** any HTTP-based service where you control the gateway. Apps you wrote, third-party HTTP APIs you front-end.

**Example beyond this demo:** an internal admin REST API; an LLM inference service; a search-index API.

### Pattern B: identity bridge to a non-JWT system (Postgres + db-app)

```
JWT  ─────►  Envoy  ─────►  db-app  ─────►  Postgres
                          (decodes JWT,    (authorizes via
                           SET ROLE)       current_user + RLS)
```

The system you're protecting can't validate JWTs — but its native auth model has a notion of "act as user X." A small bridge translates one to the other. The bridge is trivial; the actual enforcement happens at the system that owns the data.

**Suits:** databases (Postgres, MySQL with `SET PROXY_USER`, Snowflake `EXECUTE AS`), object storage (S3 with assumed IAM role), message queues (RabbitMQ vhost permissions per user).

**Example beyond this demo:** an S3-backed file service. JWT identifies user; bridge service calls AWS STS `AssumeRoleWithWebIdentity` using the JWT to get scoped S3 credentials; client uses those credentials to read/write objects keyed by their identity.

### Pattern C: native OIDC (Grafana)

```
Browser  ─────►  Service  ───OAuth2───►  IdP  ◄──── Browser
                  (handles                           (signs in directly)
                   code flow
                   end-to-end)
```

The system already implements OIDC. Just give it the IdP's URL and a client. No bridge needed.

**Suits:** modern SaaS and OSS tools that already speak OIDC: Grafana, GitLab, Argo CD, Vault UI, Kubernetes Dashboard, Jenkins (via plugin), Sonatype Nexus, etc.

**Example beyond this demo:** Argo CD with the same Keycloak realm. New `argocd` confidential client in Keycloak; configure Argo CD's `oidc.config`; the same alice/bob can sign in. Role mapping via Argo CD's projects-per-team and Keycloak group claims.

### Pattern D: short-lived signed credential for a non-JWT protocol (SSH cert)

```
JWT  ─────►  ssh-ca  ─────►  SSH cert  ─────►  sshd
                            (15-min,
                             principal=
                             JWT user)
```

The protocol has *its own* native short-lived credential format. The IdP can't issue that format directly, but a CA service can — using the JWT as proof of identity. The protocol's own server validates the credential natively.

**Suits:** any "PKI-able" protocol. SSH (this), TLS client certs (mTLS to a service), AWS STS sessions (an IAM "cert"), Kubernetes Service Account tokens (issued by the OIDC issuer in projected volume mode).

**Example beyond this demo:** mTLS for service-to-service calls. Service A authenticates to Keycloak (via M2M client_credentials grant). It calls a CA service with that JWT and gets a short-lived TLS client cert. It uses that cert to call service B over mTLS. Service B trusts the CA, validates the cert subject, authorizes accordingly.

## Generalizing: where else this pattern shows up

The bridge-to-protocol-native pattern is everywhere once you start looking. A non-exhaustive map:

| You want… | Bridge / native | What the bridge does |
|---|---|---|
| AWS access from OIDC identity | AWS STS `AssumeRoleWithWebIdentity` | Trades JWT for AWS access keys (15min–12h) |
| kubectl access from OIDC | kubectl OIDC auth provider | Refreshes ID token, sends as bearer to k8s API |
| GitHub Actions → AWS | GitHub OIDC provider + IAM role | Action's JWT → STS session, no long-lived secrets in repo |
| Vault dynamic creds | Vault `kv` + dynamic backends | OIDC login → Vault token → DB user/SSH OTP/AWS keys/etc. |
| Workload identity in k8s | ServiceAccount projected JWT + cloud OIDC | Pod's SA token → IAM/Azure AD/GCP SA, no static creds |
| SSH bastion access | Teleport / smallstep / Vault SSH | OIDC login → SSH cert (this demo's pattern) |
| Database access | HashiCorp Boundary, this demo's pattern | OIDC login → DB user / SET ROLE |
| Slack notifications from a CI job | Slack tokens | (Less common; usually long-lived bot tokens) |
| Snowflake from BI tool | OAuth2 with Snowflake | Native Snowflake OIDC |

Notice the recurring shape: **federated identity at the edge → short-lived protocol-native credential at the resource**. The bridge is sometimes a separate service (this demo's `db-app`, `ssh-ca`), sometimes a feature of the IdP itself (AWS IAM Identity Center), sometimes a feature of the resource (Vault).

## Choosing a pattern for a new backend

When you add a new backend to this kind of system, the question is "which of the four patterns applies?" Answering it is mostly mechanical:

1. **Is this an HTTP service you control or front-end with a proxy?**
   - Yes → Pattern A. Wire it behind Envoy. Same `jwt_authn` + `rbac` config that's already there.

2. **Is this a UI-driven tool that supports OIDC out of the box?**
   - Yes → Pattern C. Register an OIDC client in Keycloak. Configure the tool. Done.

3. **Does this system have a native concept of "act as user X" via a credential it understands (DB role, S3 IAM role, k8s SA token)?**
   - Yes → Pattern B. Build a bridge service that takes the JWT and obtains the system's native credential, then uses it to fulfill the request.

4. **Does this system speak a non-HTTP protocol with its own PKI/cert auth (SSH, mTLS, X.509 client auth)?**
   - Yes → Pattern D. Stand up a CA service that signs short-lived credentials from JWTs.

5. **None of the above?**
   - You're either looking at a system that wasn't designed for federated auth (IRC, raw SMTP, FTP), or you need to invent a custom pattern. Most of the time when you think "none of the above," it's actually Pattern B and you haven't found the system's native impersonation primitive yet.

## Anti-patterns

Things that look like identity-aware access but aren't:

### Sharing service-account credentials

"The app authenticates to Keycloak as the end user, then connects to Postgres as `app_user`, and queries with `WHERE owner_id = $jwt_sub`." This is application-layer authorization, not DB-layer. A SQL injection or app bug bypasses it. The DB sees only `app_user`. *No identity reaches the data layer.*

### Long-lived credentials with audit logs

"We log who triggered each action, so we can audit it later." Audit isn't enforcement — by the time you're reading the log, the action already happened. Identity-aware access *prevents* the cross-user action; audit is what you do after.

### "We use OIDC at the front door" alone

If alice can sign in but the backend uses a shared service account to talk to S3/Postgres/Redis, alice's identity is dropped at the first internal hop. The resource sees only the service account; per-user enforcement is impossible at the resource layer.

### Roles-as-identities

Granting permissions to roles like `read_only` or `admin` instead of usernames means the audit log shows what role acted, not what person. Per-user RBAC requires `principal == "alice"`, not `principal in role "engineer"`. (Roles are useful as *additional* signal, not as the primary identity unit.)

### Bearer tokens in URLs or query params

`/api/data?token=eyJhbGc...` ends up in web-server logs, browser history, referrer headers. Always pass JWTs in the `Authorization: Bearer` header (or short-lived cookies for browser sessions).

### Forever-cached JWKS

If your gateway caches Keycloak's JWKS but never refreshes, key rotation breaks every request silently. Envoy's `cache_duration` is set to 5 minutes in this demo for that reason — short enough to pick up rotation, long enough to avoid hammering the IdP.

## Production hardening checklist

For each backend integration, work through:

**Authentication:**
- [ ] Bearer JWT or browser session?
- [ ] If bearer: token validity short enough? (5-15 min for direct, longer with refresh tokens.)
- [ ] If browser session: secure, httpOnly, samesite cookie, CSRF protection.

**Authorization:**
- [ ] Coarse layer (e.g., gateway RBAC by username) and fine layer (e.g., row-level security in DB)?
- [ ] Default deny everywhere?
- [ ] Fail-closed if upstream is unreachable?

**Crypto:**
- [ ] TLS at every hop. The demo is HTTP-only for simplicity; production must be HTTPS.
- [ ] JWT signed with RS256 or ES256 (asymmetric — gateway has the public key only).
- [ ] JWKS rotated periodically; gateway picks up rotation within `cache_duration`.

**Audit:**
- [ ] Every access decision logged with: user, action, resource, decision, timestamp.
- [ ] Logs go to a SIEM, not just stdout.
- [ ] Failed-auth attempts trigger alerts above some threshold.

**Operational:**
- [ ] Bridge services scale horizontally. (`db-app`, `ssh-ca` are stateless — scale by replicas.)
- [ ] CA private keys stored in HSM or sealed Secret, not plain k8s Secret.
- [ ] Revocation: rely on short validity, not revocation lists, where possible.
- [ ] Rotation runbook exists for: IdP signing keys, CA keys, client secrets.

---

## Further reading

- [OAuth2.0 Security Best Current Practice](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-security-topics) — IETF
- [NIST Zero Trust Architecture (SP 800-207)](https://csrc.nist.gov/publications/detail/sp/800-207/final)
- [Google BeyondCorp papers](https://research.google/pubs/?team=beyondcorp) — the canonical zero-trust literature
- [HashiCorp Vault: secrets engines architecture](https://developer.hashicorp.com/vault/docs/secrets) — many of these are pattern-D bridges
- [GitHub Actions OIDC](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect) — pattern B/D for CI
- This workshop's other docs:
  - [REVERSE-PROXY.md](REVERSE-PROXY.md) — pattern A in depth
  - [POSTGRES-RLS.md](POSTGRES-RLS.md) — pattern B in depth
  - [SSH-CERTIFICATES.md](SSH-CERTIFICATES.md) — pattern D in depth
  - [OAUTH-OIDC.md](OAUTH-OIDC.md) — the OIDC layer that makes pattern C possible
