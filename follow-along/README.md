# Follow-Along Workshop

Step-by-step, copy-paste-ready. By the end you'll have logged in as `alice` and `bob`, hit four different backends with the same Keycloak identity, and seen each one enforce who-sees-what.

The four enforcement points exercised here:

| #  | Backend       | What enforces identity                                                |
| -- | ------------- | --------------------------------------------------------------------- |
| 1  | Grafana       | Native OIDC code flow against Keycloak; JMESPath role mapping         |
| 2  | HTTP apps     | Envoy `jwt_authn` + `rbac` filter on `preferred_username`             |
| 3  | SSH           | 15-min cert signed with `principal = JWT username`                    |
| 4  | Postgres      | `SET ROLE <jwt-username>` inside a tx + RLS on `current_user`         |

## Order

The first pass is sequenced deliberately — OIDC first, because it's the foundational identity flow every other backend reuses; then bearer-JWT validation at a gateway; then SSH (the cleanest "JWT → short-lived signed cert" example); then Postgres in two flavours (in-line `SET ROLE` translation, then the same cert-signing pattern again in a different protocol); finally, the audit trail capstone, which lets you see every identity decision from the previous modules show up in one structured log. After Setup, modules can be done independently if you want to skip ahead.

| File | Topic | Time |
|---|---|---|
| [00-setup.md](00-setup.md) | Build images, apply manifests, port-forward | ~5 min |
| [01-grafana-oidc.md](01-grafana-oidc.md) | OIDC code flow with Grafana — the foundation everything else uses | ~5 min |
| [02-http-authz.md](02-http-authz.md) | The same identity as a bearer JWT, validated at an API gateway | ~5 min |
| [03-ssh-certs.md](03-ssh-certs.md) | Bridging the JWT into SSH via short-lived CA-signed certs | ~5 min |
| [04-postgres-rls.md](04-postgres-rls.md) | Bridging that JWT into Postgres via SET ROLE + row-level security | ~5 min |
| [04b-postgres-direct-psql.md](04b-postgres-direct-psql.md) | Same Postgres, interactive `psql` session — JWT signs a short-lived client cert, PG enforces with native `cert` auth | ~5 min |
| [05-audit-trail.md](05-audit-trail.md) | Per-request access log keyed on verified identity (`kubectl logs \| jq`) | ~5 min |
| [06-grafana-audit.md](06-grafana-audit.md) | Same audit log, surfaced in Grafana via Loki + LogQL | ~5 min |
| [98-experiments.md](98-experiments.md) | Bonus experiments — token expiration, tampering, CA rotation | ~5 min |
| [99-cleanup.md](99-cleanup.md) | Cleanup and troubleshooting | — |

## Prerequisites

- A running Kubernetes cluster (Docker Desktop's k8s, kind, minikube, …)
- `kubectl`, `docker` (to build the local app images)
- `curl`, `jq`, `python3`, `ssh`, `ssh-keygen`, `nc` for the client-side flows
- `psql` and `openssl` for the Postgres direct-psql module (04b)

## Convention used in these files

- Every section assumes you're at the repo root unless it says otherwise.
- Token-fetching is repeated at the top of each backend section, since Keycloak access tokens expire after 5 minutes — if you're jumping in mid-workshop, you can run that block in isolation.
- Expected output is shown immediately after each command so you can compare against what you see.

→ Start with [**00-setup.md**](00-setup.md).
