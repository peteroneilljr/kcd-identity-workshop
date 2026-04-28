# Signed, Sealed, Delivered: Identity-Aware Access Demo

This repo demonstrates **per-user identity-based access control** across four different backend technologies, all keyed off a single Keycloak identity. It contrasts with traditional VPN-style access (network on/off) by showing what *each request* and *each session* can be gated on at the application/data/protocol layer.

The user logs into Keycloak once. From there, the same identity controls:

| Backend | Mechanism | What's enforced |
|---|---|---|
| HTTP services (`public`, `alice`, `bob`) | Envoy JWT validation + RBAC by `preferred_username` | Per-user, per-route HTTP authz |
| Postgres database | JWT identity forwarded → app does `SET ROLE` → row-level security | Per-user row visibility (RLS) |
| Grafana dashboard | OIDC code flow direct to Keycloak | Identity + role mapping (Admin/Viewer) |
| Ubuntu SSH | Short-lived SSH cert signed from JWT, principals = JWT username | Per-user shell access |

## Run it

Prereqs: a running cluster (Docker Desktop's k8s, kind, minikube, etc.), `kubectl`, `docker`, plus `curl`, `jq`, `ssh-keygen`, `ssh`, `python3` for the test driver.

```bash
# 1. Build the local app images. Docker Desktop's k8s shares the docker daemon's
#    image cache, so no push-to-registry is needed; on plain kind run
#    `kind load docker-image demo-...:k8s` after each build.
docker build -t demo-public-app:k8s   ./public-app
docker build -t demo-alice-app:k8s    ./alice-app
docker build -t demo-bob-app:k8s      ./bob-app
docker build -t demo-db-app:k8s       ./db-app
docker build -t demo-ssh-ca-app:k8s   ./ssh-ca-app
docker build -t demo-sshd:k8s         ./sshd-app

# 2. Apply everything. The SSH CA keypair is auto-generated on first apply
#    by a one-shot bootstrap Job (k8s/05-ssh-ca-bootstrap.yaml) — no
#    manual ssh-keygen step required. Re-applies are no-ops if the Secret
#    already exists.
kubectl apply -f k8s/

# 3. Wait for ready (≈30s on a warm cluster, longer on first pull).
kubectl -n ams-demo wait --for=condition=Available --timeout=240s deploy --all

# 4. Open the user-facing ports.
kubectl -n ams-demo port-forward svc/keycloak 8180:8180 &
kubectl -n ams-demo port-forward svc/envoy    8080:8080 &
kubectl -n ams-demo port-forward svc/grafana  3300:3000 &
kubectl -n ams-demo port-forward svc/sshd     2222:22   &
```

Then run the full assertion suite:

```bash
./tests/test-demo.sh
```

For an interactive, paused, color-coded walkthrough:

```bash
./demo-script.sh
```

## Architecture

Two distinct integration patterns live in this demo:

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

Things behind Envoy (apps, db-app, ssh-ca) all share the same JWT-validated-and-forwarded pattern. Grafana speaks OIDC natively so it goes straight to Keycloak. sshd doesn't speak HTTP at all — its trust comes from the CA public key, baked in via ConfigMap.

## How each integration works

### 1. HTTP authz: Envoy JWT + RBAC

Envoy is the choke point for `/public`, `/alice`, `/bob`, plus `/db` and `/ssh-ca/` (those last two are explained below).

- `envoy.filters.http.jwt_authn` validates Authorization-bearer JWTs against Keycloak's JWKS, decodes the payload into Envoy metadata, and forwards it to the upstream as the `x-jwt-payload` header.
- `envoy.filters.http.rbac` matches request path against the JWT's `preferred_username`:

```yaml
"allow-public":      # /public, /health, /db, /ssh-ca to anyone authenticated
  principals: [any: true]
"allow-alice-only":  # /alice only when preferred_username == "alice"
  principals: [metadata: jwt_payload.preferred_username == "alice"]
"allow-bob-only":    # /bob only when preferred_username == "bob"
  principals: [metadata: jwt_payload.preferred_username == "bob"]
```

The backends themselves don't need to validate anything — they trust Envoy's decision and just read the forwarded `x-jwt-payload` for context.

### 2. Database: SET ROLE + RLS keyed on Keycloak identity

Postgres can't validate JWTs, so the *db-app* service does the bridge:

1. Envoy lets `/db` through for any authenticated user (RLS filters per-user, not the gateway).
2. db-app decodes `x-jwt-payload`, reads `preferred_username`.
3. Inside a transaction it runs `SET LOCAL ROLE "<username>"` before querying. `SET LOCAL` is rolled back at end-of-tx, so the role can't leak across pooled connections.
4. Postgres roles `alice` and `bob` exist (`NOLOGIN`); a `dbproxy` login role is `NOINHERIT` and has `GRANT alice TO dbproxy`/`GRANT bob TO dbproxy`. The app holds no privileges until it `SET ROLE`s.
5. The `documents` table has row-level security: `USING (owner = current_user OR owner = 'public')`. The DB itself is the trust boundary — even if db-app had a bug, an alice-tx couldn't read bob's rows.

```bash
TOKEN=$(curl -s -X POST http://localhost:8180/realms/demo/protocol/openid-connect/token \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/db | jq .visible_documents
# alice sees alice's rows + the public row; bob sees bob's rows + public; never each other's.
```

For interactive psql against the same DB:

```bash
kubectl -n ams-demo port-forward svc/postgres 5432:5432 &
PGPASSWORD=dbproxy psql -h localhost -U dbproxy demo
demo=> SET ROLE alice; SELECT * FROM documents;   -- alice's view
demo=> RESET ROLE; SET ROLE bob; SELECT * FROM documents;  -- bob's view
```

### 3. Grafana: OIDC code flow direct to Keycloak

Grafana speaks OIDC natively, so Envoy is **not** in this path — putting an HTTP JWT-bearer filter in front of an OAuth code-flow would just break the redirects. Instead Grafana is configured with `auth.generic_oauth` pointing at Keycloak's `grafana` realm client.

URL split (because some calls are made by the user's browser and some by the Grafana pod itself):

| setting | URL | who hits it |
|---|---|---|
| `auth_url` | `http://localhost:8180/...` | browser (port-forwarded) |
| `token_url` | `http://keycloak:8180/...` | Grafana pod (in-cluster DNS) |
| `api_url` | `http://keycloak:8180/...` | Grafana pod (in-cluster DNS) |

`KC_HOSTNAME_URL=http://localhost:8180` on the Keycloak deployment pins the issued `iss` claim deterministically regardless of which network path delivers a token-endpoint call. `KC_HOSTNAME_STRICT_BACKCHANNEL=false` allows the in-cluster URLs on the back channel.

Role mapping is a JMESPath expression:

```ini
role_attribute_path = contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'
```

So:
- alice (realm roles: `[user]`) → Grafana **Viewer**
- bob (realm roles: `[user, admin]`) → Grafana **Admin**

To use it: open `http://localhost:3300/login`, click *Sign in with Keycloak*, log in as `alice/password` or `bob/password`. First login auto-provisions the user inside Grafana.

### 4. SSH: short-lived certs signed from JWT

The pattern: turn an authenticated JWT into a **15-minute SSH user certificate** whose principal is the JWT's `preferred_username`. sshd is configured to trust the demo CA, but only honors certs whose principal matches a per-unix-user file.

Components:
- `ssh-ca` HTTP service (behind Envoy, same `x-jwt-payload` pattern as db-app). On `POST /ssh-ca/sign`, it shells out to `ssh-keygen -s ca -I <id> -n <preferred_username> -V +15m <user_pubkey>`.
- `sshd` pod (Ubuntu 22.04). `sshd_config` has `TrustedUserCAKeys /etc/ssh/ca.pub`, `AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u`, and `AuthorizedKeysFile none` so the only path in is via a CA-signed cert with the right principal. Each unix user (`alice`, `bob`) has only their own name in their principals file — alice's cert can never be used as bob.

End-user flow:

```bash
# 1. Local SSH keypair (do once; reuse forever).
ssh-keygen -t ed25519 -f ~/.ssh/keycloak_id -N ""

# 2. Get a Keycloak token, exchange for a 15-min SSH cert.
TOKEN=$(curl -s -X POST http://localhost:8180/realms/demo/protocol/openid-connect/token \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain" --data-binary @$HOME/.ssh/keycloak_id.pub \
  http://localhost:8080/ssh-ca/sign > $HOME/.ssh/keycloak_id-cert.pub

# 3. SSH in (the ssh client picks up *-cert.pub next to the key automatically).
ssh -i ~/.ssh/keycloak_id -p 2222 alice@localhost
```

Layered enforcement:
1. **Envoy** rejects `/ssh-ca/sign` without a valid Keycloak JWT (401).
2. **ssh-ca** ignores any user-supplied identity — `Principals` is set strictly from `preferred_username`. The CA private key is mounted read-only via a Secret with `defaultMode: 0440 + fsGroup:1001` so the unprivileged signer process can read it.
3. **sshd** verifies the cert was signed by the trusted CA *and* that the principal is in the target user's `auth_principals` file.
4. **15-min validity** — short enough that revocation infra isn't worth building.

## Access control matrix

| User  | `/public` | `/alice` | `/bob` | `/db`  | `/db` rows visible | Grafana role | `ssh alice@host` | `ssh bob@host` |
| ----- | --------- | -------- | ------ | ------ | ------------------ | ------------ | ---------------- | -------------- |
| none  | 401       | 401      | 401    | 401    | —                  | —            | denied           | denied         |
| alice | 200       | 200      | 403    | 200    | `{alice, public}`  | Viewer       | logged in        | denied         |
| bob   | 200       | 403      | 200    | 200    | `{bob, public}`    | Admin        | denied           | logged in      |

## Identities (Keycloak realm `demo`)

- `alice` / `password` — realm roles `[user]`
- `bob`   / `password` — realm roles `[user, admin]`

Two confidential clients: `demo-client` (used by curl + apps) and `grafana` (the Grafana OIDC client).

## End-to-end test (run after `kubectl apply -f k8s/`)

There's no committed test runner yet, but the full matrix below is what gets exercised on every clean rebuild — 25 assertions across the four suites, all expected to pass. Drop this into a script if you want to wire it into CI:

- HTTP authz: anon→401 except `/health`; alice can `/public`/`/alice` but `/bob`→403; bob mirror-image. (10 cases)
- DB RLS: alice's `/db` returns `{owner: alice, public}` rows only; bob → `{bob, public}`; anon→401. (3 cases)
- Grafana OIDC: full curl-driven code flow (visit `/login/generic_oauth`, scrape login form action, POST creds, follow redirects, hit `/api/user/orgs`); alice→Viewer, bob→Admin. (2 cases)
- SSH: alice signs and ssh's as alice; alice's cert refused for bob; bob mirror; anon→401 from ssh-ca; naked key (no cert)→denied. (10 cases)

## Threat model & security notes

| Attack | Protected? | How |
|---|---|---|
| No authentication | ✅ | Envoy JWT filter / Grafana OIDC start / sshd cert-only |
| Expired/forged JWT | ✅ | Signature verified against JWKS; `exp` checked |
| Cross-user HTTP access (alice → /bob) | ✅ | RBAC denies (403) |
| Cross-user DB rows (alice tx reads bob rows) | ✅ | Postgres RLS, enforced by DB regardless of app bugs |
| Cross-user SSH (alice's cert as `ssh bob@host`) | ✅ | sshd principals file mismatch |
| Compromised db-app process forging identity | ✅ | dbproxy is `NOINHERIT`, so process has no privileges until it `SET ROLE`s — and the JWT was already validated by Envoy upstream |
| Stolen SSH cert | ⚠️ | Valid until expiration (15 min). No revocation list. |
| Stolen JWT | ⚠️ | Same — short lifetime mitigates |
| Network sniffing | ❌ | Demo is HTTP-only. Production: TLS at Envoy + sshd already encrypted |
| Direct backend access bypassing Envoy | ✅ in-cluster | Apps only have ClusterIP; nothing exposed without `port-forward` |

Production hardening is roughly the same checklist as the original demo — TLS, refresh tokens, rate limiting, log aggregation, JWKS rotation, replace public-client password grant with a confidential client + auth-code-with-PKCE for browser apps, etc.

## Cleanup

```bash
kubectl delete namespace ams-demo
```

## Layout

```
public-app/  alice-app/  bob-app/         HTTP services (ports 3000/3002/3001)
db-app/                                   Postgres bridge (reads JWT, SET ROLE, queries)
ssh-ca-app/                               SSH cert authority (HTTP, signs from JWT)
sshd-app/                                 Ubuntu SSH server pod
keycloak/realm-export.json                Keycloak realm with users + clients

k8s/                                      Kubernetes manifests, applied with kubectl apply -f k8s/
  00-namespace.yaml ... 73-sshd.yaml      ordered to make read-through obvious
  config-src/                             non-manifest sources (envoy.yaml, init.sql, ssh-ca keys)
                                          regenerate ConfigMaps if you edit these:
                                            kubectl create configmap ... --from-file=... \
                                              --dry-run=client -o yaml > k8s/30-envoy-config.yaml

demo-script.sh                            interactive paused walkthrough (k8s; pause/Enter on each step)
tests/test-demo.sh                        full assertion suite (k8s)
FOLLOW-ALONG.md                           copy-paste-ready step-by-step guide
docs/                                     conceptual deep dives (proxy, OAuth/OIDC, JWTs, logging)
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
