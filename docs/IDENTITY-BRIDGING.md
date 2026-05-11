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

### Pattern A: native OIDC (Grafana)

```
Browser  ─────►  Service  ───OAuth2───►  IdP  ◄──── Browser
                  (handles                           (signs in directly)
                   code flow
                   end-to-end)
```

The system already implements OIDC. Just give it the IdP's URL and a client. No bridge needed.

**Suits:** modern SaaS and OSS tools that already speak OIDC: Grafana, GitLab, Argo CD, Vault UI, Kubernetes Dashboard, Jenkins (via plugin), Sonatype Nexus, etc.

**Example beyond this demo:** Argo CD with the same Keycloak realm. New `argocd` confidential client in Keycloak; configure Argo CD's `oidc.config`; the same alice/bob can sign in. Role mapping via Argo CD's projects-per-team and Keycloak group claims.

### Pattern B: short-lived signed credential for a non-JWT protocol (SSH cert)

```
JWT  ─────►  ssh-ca  ─────►  SSH cert  ─────►  sshd
                            (15-min,
                             principal=
                             JWT user)
```

The protocol has *its own* native short-lived credential format. The IdP can't issue that format directly, but a CA service can — using the JWT as proof of identity. The protocol's own server validates the credential natively.

**Suits:** any "PKI-able" protocol. SSH (this), TLS client certs (mTLS to a service), AWS STS sessions (an IAM "cert"), Kubernetes Service Account tokens (issued by the OIDC issuer in projected volume mode).

**Example beyond this demo:** mTLS for service-to-service calls. Service A authenticates to Keycloak (via M2M client_credentials grant). It calls a CA service with that JWT and gets a short-lived TLS client cert. It uses that cert to call service B over mTLS. Service B trusts the CA, validates the cert subject, authorizes accordingly.

### Pattern C: bearer-token gateway (HTTP services)

```
JWT  ─────►  Envoy  ─────►  backend
          (verifies,
           applies RBAC,
           forwards claims)
```

The most direct shape. The proxy validates the JWT for the backend, applies its own coarse authorization (RBAC by username), and forwards the verified claims so the backend can do its own fine-grained checks if it wants to. Backends never have to know about JWTs.

**Suits:** any HTTP-based service where you control the gateway. Apps you wrote, third-party HTTP APIs you front-end.

**Example beyond this demo:** an internal admin REST API; an LLM inference service; a search-index API.

### Pattern D: identity bridge to a non-JWT system (Postgres + db-app)

```
JWT  ─────►  Envoy  ─────►  db-app  ─────►  Postgres
                          (decodes JWT,    (authorizes via
                           SET ROLE)       current_user + RLS)
```

The system you're protecting can't validate JWTs — but its native auth model has a notion of "act as user X." A small bridge translates one to the other. The bridge is trivial; the actual enforcement happens at the system that owns the data.

**Suits:** databases (Postgres, MySQL with `SET PROXY_USER`, Snowflake `EXECUTE AS`), object storage (S3 with assumed IAM role), message queues (RabbitMQ vhost permissions per user).

**Example beyond this demo:** an S3-backed file service. JWT identifies user; bridge service calls AWS STS `AssumeRoleWithWebIdentity` using the JWT to get scoped S3 credentials; client uses those credentials to read/write objects keyed by their identity.
