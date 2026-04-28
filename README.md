# KCD Identity Workshop: Using identity for direct secure access to infrastructure

This repo demonstrates **per-user identity-based access control** across four different backend technologies, all keyed off a single Keycloak identity. It's a study in *what each request* and *each session* can be gated on at the application/data/protocol layer — the inverse of VPN-style network-level trust.

The user authenticates to Keycloak once. From there, the same identity controls:

| Backend | Mechanism | What's enforced |
|---|---|---|
| Grafana dashboard | OIDC code flow direct to Keycloak | Identity + role mapping (Admin/Viewer) |
| HTTP services (`public`, `alice`, `bob`) | Envoy JWT validation + RBAC by `preferred_username` | Per-user, per-route HTTP authz |
| Postgres database | JWT identity forwarded → app does `SET ROLE` → row-level security | Per-user row visibility (RLS) |
| Ubuntu SSH | Short-lived SSH cert signed from JWT, principals = JWT username | Per-user shell access |

> **Hands-on workshop modules** live in [`follow-along/`](follow-along/) — one self-contained file per backend, each runnable in ~5 minutes. This README is a tour of *what* and *why*; that directory is the *how*.

## Architecture

![Identity-Aware Access architecture: Keycloak as the identity provider; users reach Envoy with a Bearer JWT, Grafana via OIDC code flow, and sshd with a CA-signed cert; behind Envoy are public/alice/bob HTTP apps plus db-app (which SET ROLEs into Postgres with row-level security) and ssh-ca (which signs SSH certs whose principal is the JWT username, trusted by sshd's CA pubkey).](docs/architecture.png)

<!--
  docs/architecture.png is the rendered export of docs/architecture.excalidraw.
  To regenerate after editing the source:
    1. Open https://excalidraw.com/#json=bbwfex_7LwEewrH5OtHYI,L1jy0RjmtDQuEwW_x_xcVA
       (or import docs/architecture.excalidraw)
    2. File → Export image → PNG, "with background", scale 2x
    3. Save as docs/architecture.png
-->

> **Edit the diagram:** [`docs/architecture.excalidraw`](docs/architecture.excalidraw) is the source. Open it in [excalidraw.com](https://excalidraw.com), the [Excalidraw VS Code extension](https://marketplace.visualstudio.com/items?itemName=pomdtr.excalidraw-editor), or any tool that reads `.excalidraw` JSON. Live interactive copy is also at <https://excalidraw.com/#json=bbwfex_7LwEewrH5OtHYI,L1jy0RjmtDQuEwW_x_xcVA>.

ASCII fallback (also useful in terminals):

```
                                ┌──────────────────────┐
                                │       Keycloak       │
                                │     port 8180        │
                                └─┬──────────────────┬─┘
                                  │ JWKS / OIDC      │
                                  │                  │
                                  ▼                  │
   ┌──────────────────────────────────────┐          │
   │         Envoy   port 8080            │          │
   │  jwt_authn → rbac → route            │          │
   └─┬──────┬──────┬──────┬──────┬────────┘          │
     │      │      │      │      │                   │
     ▼      ▼      ▼      ▼      ▼                   │
  public  alice   bob   db-app  ssh-ca               │
                          │       │                  │
                          │       │ ssh-keygen -s    │
                          ▼       │   principal=     │
                       Postgres   │   <jwt user>     │
                      RLS by      │                  │
                      current_user│   user runs      │
                                  ▼   ssh -i cert    │
                              [SSH cert]──────────► sshd
                                                  Ubuntu, trusts CA pubkey

                              ┌─── direct OIDC, not through Envoy ────┐
                              │                                       │
                              ▼                                       │
                          Grafana port 3000 ◄──── browser code flow ──┘
```

Two distinct integration patterns coexist:

- **Behind Envoy** (apps, `db-app`, `ssh-ca`): Envoy is the choke point. It validates JWTs, enforces RBAC, and forwards verified claims to upstreams as `x-jwt-payload`. Backends trust Envoy's decision and use the forwarded identity for their own authorization layer.
- **Side channels** (Grafana, sshd): protocol-native. Grafana speaks OIDC and goes straight to Keycloak; sshd speaks SSH cert auth and trusts the demo CA's pubkey baked into a ConfigMap. Putting Envoy in front of either would break their native auth flows.

## Components

What each tool is, and why it's in this stack.

### Keycloak — identity provider

The single source of truth for *who* a user is. Hosts the `demo` realm with two users (`alice`, `bob`), the `demo-client` (used for password-grant flows by curl + apps), and the `grafana` confidential client (used for Grafana's OIDC code flow). It signs JWTs with RS256, publishes its public keys at a JWKS endpoint, and serves the standard OIDC discovery document. Everything else in this stack defers to Keycloak for "is this person who they say they are?"

### Envoy — gateway and authz enforcement layer

A single ingress for the HTTP services. Two filters do the work:

- `envoy.filters.http.jwt_authn` — fetches Keycloak's JWKS, verifies bearer JWTs on every request, decodes claims into per-request metadata, and forwards them to the upstream as the `x-jwt-payload` header.
- `envoy.filters.http.rbac` — matches request path against a verified claim (here, `preferred_username`) and decides ALLOW or DENY per route.

Backends never have to validate anything themselves; they trust Envoy and read forwarded claims for context. Adding a new HTTP service is just a new cluster + route + RBAC policy in `envoy.yaml`.

### Postgres + db-app — JWT identity bridged into a non-JWT system

Postgres can't validate JWTs natively. `db-app` is a thin Node service that reads the JWT identity Envoy forwarded, opens a tx, runs `SET LOCAL ROLE "<username>"`, and queries. Postgres' row-level security (`USING owner = current_user OR owner = 'public'`) then filters per row at the DB layer — *not* at the application. The `dbproxy` connection user is `NOINHERIT` and has no privileges of its own, so the only way to see anyone's data is via `SET ROLE`. The trust boundary is the database.

### Grafana — OIDC-native dashboard

Grafana's `auth.generic_oauth` provider is configured to do the standard OAuth2 authorization-code flow against Keycloak. The browser bounces to Keycloak, the user signs in, Keycloak redirects back with a code, Grafana exchanges it for tokens, reads the user's identity and `realm_access.roles` claim, and (on first login) auto-provisions a Grafana user. A JMESPath role-attribute mapping turns the realm role `admin` into Grafana role `Admin`; everything else is `Viewer`.

This part is a study in contrast: Envoy is *not* in the path, because OAuth code-flow redirects don't compose well with bearer-JWT gateways.

### ssh-ca + sshd — short-lived certificates from a JWT

`ssh-ca` is another small HTTP service behind Envoy. On `POST /ssh-ca/sign` with a valid JWT and your SSH public key, it shells out to `ssh-keygen -s ca -n <preferred_username> -V +15m <userkey>` and returns a 15-minute SSH user certificate. The cert's `Principal` is set strictly from the JWT — clients can't ask to be signed for someone else.

`sshd` runs in an Ubuntu pod with `TrustedUserCAKeys /etc/ssh/ca.pub` (the demo CA's public key, mounted from a ConfigMap), per-user `AuthorizedPrincipalsFile`s, and `AuthorizedKeysFile=none`. So the *only* way in is a CA-signed cert whose principal matches the unix username — alice's cert can never log in as bob.

This is the same architectural pattern as Teleport, Vault SSH secrets engine, or smallstep — *use OIDC to obtain short-lived signed credentials, then use those for the protocol's native auth*. Doing it ourselves in ~50 lines of Node + a few manifests demystifies what those products are doing internally.

### Bootstrap Job — zero-touch CA generation

`k8s/05-ssh-ca-bootstrap.yaml` runs once on first apply. It generates a fresh ed25519 keypair with `ssh-keygen` and creates the `Secret/ssh-ca-key` and `ConfigMap/ssh-ca-pub` that `ssh-ca` and `sshd` mount. Idempotent — re-applies are no-ops. Removes the manual "generate CA before applying" step that workshops can't tolerate.

### Loki + Promtail — audit-trail surface in Grafana

`Loki` (single-binary, deployed by `k8s/80-loki.yaml`) is the log-aggregation backend. `Promtail` (DaemonSet, `k8s/81-promtail.yaml`) auto-discovers pods in `ams-demo`, scrapes their stdout, and ships log lines to Loki with labels (`app`, `pod`, `container`). The existing Grafana is provisioned (`k8s/82-grafana-provisioning.yaml`) with Loki as a data source and a pre-built **Identity Audit Trail** dashboard, so the OIDC-protected dashboard you logged into in module 01 now actually has something to show: per-user request rate over time, 401/403/200 stat tiles, a filterable log stream. Same Envoy access log, surfaced for ops/admin consumption rather than `kubectl logs | jq`.

### Image mirror workflow — registry-independence

`.github/workflows/mirror-images.yml` mirrors the 7 third-party images this stack pulls (alpine, postgres, grafana, envoy, keycloak, loki, promtail) into GHCR using `docker buildx imagetools create` (preserves multi-arch manifests). The cluster pulls everything from `ghcr.io/peteroneilljr/kcd-identity-workshop/*` instead of Docker Hub / Quay, so workshop attendees on shared conference Wi-Fi don't trip Docker Hub's anonymous pull rate limit.

## How identity flows through each backend

The four subsections below match the order of the `follow-along/` workshop modules. OIDC comes first because it's the foundational identity flow every other backend reuses; bearer-JWT validation at a gateway comes next; then the two non-JWT-native backends bridged in.

### 1. Grafana via OIDC code flow

Standard OAuth2 authorization code grant — the user-visible "log in with Keycloak" flow. The interesting wrinkle is the URL split — *whose* network namespace makes each call:

| setting | URL | who hits it |
|---|---|---|
| `auth_url` | `http://localhost:8180/...` | the user's **browser** (port-forwarded) |
| `token_url` | `http://keycloak:8180/...` | the **Grafana pod** (in-cluster DNS) |
| `api_url` | `http://keycloak:8180/...` | the **Grafana pod** (in-cluster DNS) |

`KC_HOSTNAME_URL=http://localhost:8180` on the Keycloak deployment pins the JWT `iss` claim deterministically regardless of network path; `KC_HOSTNAME_STRICT_BACKCHANNEL=false` permits the in-cluster URLs on the back channel.

Role mapping is a JMESPath:

```ini
role_attribute_path = contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'
```

So `alice` (realm roles `[user]`) → Grafana **Viewer**; `bob` (realm roles `[user, admin]`) → Grafana **Admin**.

→ Hands-on: [`follow-along/01-grafana-oidc.md`](follow-along/01-grafana-oidc.md)

### 2. HTTP via Envoy JWT + RBAC

The conceptual flow:

```
client ──Bearer JWT──► Envoy ──verify sig────► validate iss/exp ────►
                              ──extract claims──► put in metadata ───►
                              ──RBAC: path × preferred_username────►
                              ──forward x-jwt-payload──► backend
```

The RBAC policies key on **identity**, not roles:

```yaml
"allow-alice-only":  permissions: [/alice]   principals: [preferred_username == "alice"]
"allow-bob-only":    permissions: [/bob]     principals: [preferred_username == "bob"]
"allow-public":      permissions: [/public, /health, /db, /ssh-ca]   principals: [any: true]
```

Bob has the `admin` realm role, but it doesn't unlock alice's app — RBAC checks the username, not the role. *Authentication ≠ authorization*.

→ Hands-on: [`follow-along/02-http-authz.md`](follow-along/02-http-authz.md)

### 3. Database via SET ROLE + RLS

Same JWT, different enforcement layer — and the first **bridge** in the workshop (a system that can't speak JWT at all):

```
client ──Bearer JWT──► Envoy ──verify──► forward x-jwt-payload ──► db-app
                                                                      │
                                              BEGIN; SET LOCAL ROLE "<jwt-user>";
                                              SELECT * FROM documents;
                                              COMMIT;
                                                                      ▼
                                                                 Postgres
                                                                  RLS: owner = current_user
                                                                       OR owner = 'public'
```

The DB itself is the authority on who-sees-what. Even if `db-app` had a bug or got compromised, the worst case is running as `dbproxy`, which has no privileges of its own — only what it inherits via `SET ROLE`. RLS is enforced regardless of application correctness.

→ Hands-on: [`follow-along/03-postgres-rls.md`](follow-along/03-postgres-rls.md)

### 4. SSH via short-lived CA-signed certs

The second bridge — same JWT, this time turned into a credential a non-HTTP protocol understands. Layered enforcement, failures at any one of these stops the chain:

1. **Envoy** rejects `/ssh-ca/sign` without a valid Keycloak JWT (401).
2. **`ssh-ca`** ignores any user-supplied identity. The cert's `Principals=` field is set strictly from the JWT's `preferred_username`. The CA private key is mounted read-only via Secret with `defaultMode: 0440` + `fsGroup: 1001`.
3. **sshd** verifies the cert was signed by the trusted CA *and* that the principal is in the per-unix-user `auth_principals` file. `AuthorizedKeysFile=none` means there's no fallback to plain key auth.
4. **15-minute validity** makes revocation infrastructure unnecessary — a stolen cert is worthless quickly.

→ Hands-on: [`follow-along/04-ssh-certs.md`](follow-along/04-ssh-certs.md)

## Access control matrix

| User  | `/public` | `/alice` | `/bob` | `/db`  | `/db` rows visible | Grafana role | `ssh alice@host` | `ssh bob@host` |
| ----- | --------- | -------- | ------ | ------ | ------------------ | ------------ | ---------------- | -------------- |
| none  | 401       | 401      | 401    | 401    | —                  | —            | denied           | denied         |
| alice | 200       | 200      | 403    | 200    | `{alice, public}`  | Viewer       | logged in        | denied         |
| bob   | 200       | 403      | 200    | 200    | `{bob, public}`    | Admin        | denied           | logged in      |

## Identities (Keycloak realm `demo`)

- `alice` / `password` — realm roles `[user]`
- `bob`   / `password` — realm roles `[user, admin]`

Two clients: `demo-client` (used by curl + apps) and `grafana` (the Grafana OIDC client).

## Threat model

| Attack | Protected? | How |
|---|---|---|
| No authentication | ✅ | Envoy JWT filter / Grafana OIDC start / sshd cert-only |
| Expired/forged JWT | ✅ | Signature verified against JWKS; `exp` checked |
| Cross-user HTTP access (alice → /bob) | ✅ | Envoy RBAC denies (403) |
| Cross-user DB rows (alice tx reads bob rows) | ✅ | Postgres RLS, enforced by DB regardless of app bugs |
| Cross-user SSH (alice's cert as `ssh bob@host`) | ✅ | sshd principals file mismatch |
| Compromised db-app process forging identity | ✅ | dbproxy is `NOINHERIT`, so process has no privileges until it `SET ROLE`s — and the JWT was already validated by Envoy upstream |
| Stolen SSH cert | ⚠️ | Valid until expiration (15 min). No revocation list. |
| Stolen JWT | ⚠️ | Same — short lifetime mitigates |
| Network sniffing | ❌ | Demo is HTTP-only. Production: TLS at Envoy + sshd already encrypted |
| Direct backend access bypassing Envoy | ✅ in-cluster | Apps only have ClusterIP; nothing exposed without `port-forward` |

Production hardening from here: TLS termination at Envoy, refresh-token flow instead of password grant, rate limiting per user, log aggregation, JWKS rotation, replace public-client password grant with confidential client + auth-code-with-PKCE for browser apps.

## Layout

```
public-app/  alice-app/  bob-app/         HTTP services (ports 3000/3002/3001)
db-app/                                   Postgres bridge — reads JWT, SET ROLE, queries
ssh-ca-app/                               SSH cert authority — HTTP, signs from JWT
sshd-app/                                 Ubuntu SSH server pod
keycloak/realm-export.json                Keycloak realm: users, clients, role mappings

k8s/                                      Kubernetes manifests, applied with kubectl apply -f k8s/
  00-namespace.yaml ... 73-sshd.yaml      ordered to make read-through obvious
  config-src/                             non-manifest sources (envoy.yaml, init.sql) used to
                                          regenerate ConfigMaps when edited

follow-along/                             workshop modules — one self-contained file per backend
demo-script.sh                            interactive paused walkthrough (color-coded)
tests/test-demo.sh                        full assertion suite (25 cases across 4 suites)
.github/workflows/mirror-images.yml       mirrors upstream images into GHCR
docs/                                     conceptual deep dives (proxy, OAuth/OIDC, JWTs, logging)
docs/architecture.excalidraw              editable source of the architecture diagram above
```

## Further reading

- [Reverse Proxy Architecture](docs/REVERSE-PROXY.md)
- [OAuth2 and OIDC](docs/OAUTH-OIDC.md)
- [JWT Tokens](docs/JWT-JSON-WEB-TOKEN.md)
- [Access Logging](docs/ACCESS-LOGGING.md)
- [Envoy JWT Authentication](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter)
- [Envoy RBAC](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter)
- [PostgreSQL Row-Level Security](https://www.postgresql.org/docs/16/ddl-rowsecurity.html)
- [Grafana generic OAuth](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)
- [OpenSSH certificate authentication](https://man.openbsd.org/ssh-keygen#CERTIFICATES)
