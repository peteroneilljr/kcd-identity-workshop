# Container build contexts

One folder per image. CI builds each one and pushes to `ghcr.io/peteroneilljr/kcd-identity-workshop/<name>:latest` — see [`.github/workflows/build-demo-images.yml`](../.github/workflows/build-demo-images.yml). Workshop attendees never need to build locally; `kubectl apply -f k8s/` pulls everything from GHCR.

| Folder | Image | Role |
|---|---|---|
| [`public-app/`](public-app/) | `demo-public-app` | HTTP service, allow-any-authenticated user (port 3000) |
| [`alice-app/`](alice-app/) | `demo-alice-app` | HTTP service, only alice can hit (port 3002) |
| [`bob-app/`](bob-app/) | `demo-bob-app` | HTTP service, only bob can hit (port 3001) |
| [`db-app/`](db-app/) | `demo-db-app` | Postgres bridge — reads `x-jwt-payload`, `SET LOCAL ROLE`, queries (port 3003) |
| [`ssh-ca-app/`](ssh-ca-app/) | `demo-ssh-ca-app` | SSH cert authority — HTTP, signs SSH user certs from JWT (port 3004) |
| [`pg-ca-app/`](pg-ca-app/) | `demo-pg-ca-app` | Postgres client-cert authority — HTTP, signs PG client certs from JWT (port 3005) |
| [`sshd-app/`](sshd-app/) | `demo-sshd` | Ubuntu sshd pod, trusts `ssh-ca`'s pubkey via `TrustedUserCAKeys` |
| [`postgres-app/`](postgres-app/) | `demo-postgres` | `postgres:16-bookworm` + pgaudit, built so we get the audit extension |

## Local iteration

Manifests use `imagePullPolicy: IfNotPresent`, so if you re-tag a fresh local build with the GHCR name, the kubelet uses the local one:

```bash
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-public-app:latest   ./public-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-alice-app:latest    ./alice-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-bob-app:latest      ./bob-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-db-app:latest       ./db-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-ssh-ca-app:latest   ./ssh-ca-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-pg-ca-app:latest    ./pg-ca-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-sshd:latest         ./sshd-app
docker build -t ghcr.io/peteroneilljr/kcd-identity-workshop/demo-postgres:latest     ./postgres-app
```

(Run from this directory, or prefix each path with `docker/` from the repo root.)

Docker Desktop's Kubernetes shares the docker daemon's image cache automatically. On `kind`, follow each build with `kind load docker-image <tag>`. Pushing a fresh tag to GHCR happens via the [build-demo-images workflow](../.github/workflows/build-demo-images.yml) — either auto on push-to-main or manually via `gh workflow run "build demo images"`.

## What's where

The 8 demo images carry workshop-specific code (`alice-app` is a one-liner that returns the JWT claims, `db-app` is the SET-ROLE bridge, etc.). The 6 third-party base images the cluster pulls at apply-time (alpine, grafana, envoy, keycloak, loki, promtail) come from the same GHCR namespace via a separate mirror — see [`.github/workflows/mirror-images.yml`](../.github/workflows/mirror-images.yml). Net result: every image the workshop touches lives under `ghcr.io/peteroneilljr/kcd-identity-workshop/*`, so attendees never hit Docker Hub's anonymous-pull rate limit.

## Conceptual context

- HTTP/RBAC pattern: [`docs/REVERSE-PROXY.md`](../docs/REVERSE-PROXY.md)
- The bridge services (`db-app`, `ssh-ca`, `pg-ca`): [`docs/POSTGRES-RLS.md`](../docs/POSTGRES-RLS.md), [`docs/SSH-CERTIFICATES.md`](../docs/SSH-CERTIFICATES.md)
- Hands-on flows that exercise each of these images: [`follow-along/`](../follow-along/)
