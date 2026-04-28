# Container build contexts

One folder per image. Each is a standalone build context — the only thing the cluster needs is the resulting `:k8s` tag in the local Docker daemon.

| Folder | Image | Role |
|---|---|---|
| [`public-app/`](public-app/) | `demo-public-app:k8s` | HTTP service, allow-any-authenticated user (port 3000) |
| [`alice-app/`](alice-app/) | `demo-alice-app:k8s` | HTTP service, only alice can hit (port 3002) |
| [`bob-app/`](bob-app/) | `demo-bob-app:k8s` | HTTP service, only bob can hit (port 3001) |
| [`db-app/`](db-app/) | `demo-db-app:k8s` | Postgres bridge — reads `x-jwt-payload`, `SET LOCAL ROLE`, queries (port 3003) |
| [`ssh-ca-app/`](ssh-ca-app/) | `demo-ssh-ca-app:k8s` | SSH cert authority — HTTP, signs SSH user certs from JWT (port 3004) |
| [`pg-ca-app/`](pg-ca-app/) | `demo-pg-ca-app:k8s` | Postgres client-cert authority — HTTP, signs PG client certs from JWT (port 3005) |
| [`sshd-app/`](sshd-app/) | `demo-sshd:k8s` | Ubuntu sshd pod, trusts `ssh-ca`'s pubkey via `TrustedUserCAKeys` |
| [`postgres-app/`](postgres-app/) | `demo-postgres:k8s` | `postgres:16-bookworm` + pgaudit, built locally so we get the audit extension |

## Build everything

```bash
docker build -t demo-public-app:k8s   ./public-app
docker build -t demo-alice-app:k8s    ./alice-app
docker build -t demo-bob-app:k8s      ./bob-app
docker build -t demo-db-app:k8s       ./db-app
docker build -t demo-ssh-ca-app:k8s   ./ssh-ca-app
docker build -t demo-pg-ca-app:k8s    ./pg-ca-app
docker build -t demo-sshd:k8s         ./sshd-app
docker build -t demo-postgres:k8s     ./postgres-app
```

(Run from this directory, or prefix each path with `docker/` from the repo root — same as [`follow-along/00-setup.md`](../follow-along/00-setup.md) does.)

Docker Desktop's Kubernetes shares the docker daemon's image cache automatically. On `kind`, follow each build with `kind load docker-image <tag>`.

## Why these are local

The 8 demo images carry workshop-specific code (`alice-app` is just a one-liner that returns the JWT claims, `db-app` is the SET-ROLE bridge, etc.). The 6 third-party base images the cluster pulls at apply-time (alpine, grafana, envoy, keycloak, loki, promtail) come from the workshop's GHCR mirror — see [`.github/workflows/mirror-images.yml`](../.github/workflows/mirror-images.yml).

## Conceptual context

- HTTP/RBAC pattern: [`docs/REVERSE-PROXY.md`](../docs/REVERSE-PROXY.md)
- The bridge services (`db-app`, `ssh-ca`, `pg-ca`): [`docs/POSTGRES-RLS.md`](../docs/POSTGRES-RLS.md), [`docs/SSH-CERTIFICATES.md`](../docs/SSH-CERTIFICATES.md)
- Hands-on flows that exercise each of these images: [`follow-along/`](../follow-along/)
