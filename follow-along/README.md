# Follow-Along Workshop

Step-by-step, copy-paste-ready. By the end you'll have logged in as `alice` and `bob`, hit four different backends with the same Keycloak identity, and seen each one enforce who-sees-what.

The four enforcement points exercised here:

| #  | Backend       | What enforces identity                                                |
| -- | ------------- | --------------------------------------------------------------------- |
| 1  | HTTP apps     | Envoy `jwt_authn` + `rbac` filter on `preferred_username`             |
| 2  | Postgres      | `SET ROLE <jwt-username>` inside a tx + RLS on `current_user`         |
| 3  | Grafana       | Native OIDC code flow against Keycloak; JMESPath role mapping         |
| 4  | SSH           | 15-min cert signed with `principal = JWT username`                    |

## Order

Do these in order on first pass — each builds on the cluster spun up by **00**. After Setup, the four backends are independent: skip ahead to whichever interests you.

| File | Topic | Time |
|---|---|---|
| [00-setup.md](00-setup.md) | Build images, apply manifests, port-forward | ~5 min |
| [01-http-authz.md](01-http-authz.md) | HTTP gated by JWT + per-user RBAC | ~5 min |
| [02-postgres-rls.md](02-postgres-rls.md) | DB rows scoped per identity via RLS | ~5 min |
| [03-grafana-oidc.md](03-grafana-oidc.md) | Browser SSO with realm-role-to-Grafana-role mapping | ~5 min |
| [04-ssh-certs.md](04-ssh-certs.md) | SSH access via short-lived CA-signed certs | ~5 min |
| [99-cleanup.md](99-cleanup.md) | Cleanup, troubleshooting, extra experiments | — |

## Prerequisites

- A running Kubernetes cluster (Docker Desktop's k8s, kind, minikube, …)
- `kubectl`, `docker` (to build the local app images)
- `curl`, `jq`, `python3`, `ssh`, `ssh-keygen`, `nc` for the client-side flows

## Convention used in these files

- Every section assumes you're at the repo root unless it says otherwise.
- Token-fetching is repeated at the top of each backend section, since Keycloak access tokens expire after 5 minutes — if you're jumping in mid-workshop, you can run that block in isolation.
- Expected output is shown immediately after each command so you can compare against what you see.

→ Start with [**00-setup.md**](00-setup.md).
