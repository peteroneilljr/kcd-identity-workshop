# Kubernetes manifests

Apply with:

```bash
kubectl apply -f .            # from this directory
# or
kubectl apply -f k8s/         # from the repo root
```

Everything lands in the `ams-demo` namespace. Order is encoded in the filename prefix — `kubectl apply -f` processes alphabetically, so the `00-…99-` numbering is the apply order.

## File numbering

| Prefix | What | Files |
|---|---|---|
| `00-` | Namespace | `00-namespace.yaml` |
| `05-` / `06-` | Bootstrap Jobs (CA keypair generators) | `05-ssh-ca-bootstrap.yaml`, `06-pg-ca-bootstrap.yaml` |
| `10-` / `11-` | Keycloak + realm export ConfigMap | `10-keycloak.yaml`, `11-keycloak-realm-cm.yaml` |
| `20-` | HTTP backend apps (`public`, `alice`, `bob`) | `20-apps.yaml` |
| `30-` / `31-` | Envoy (config ConfigMap + Deployment/Service) | `30-envoy-config.yaml`, `31-envoy.yaml` |
| `40-` / `41-` | Postgres + init SQL + pg_hba ConfigMaps | `40-postgres-hba-cm.yaml`, `40-postgres-init-cm.yaml`, `41-postgres.yaml` |
| `50-` | `db-app` (Postgres bridge) | `50-db-app.yaml` |
| `60-` | Grafana | `60-grafana.yaml` |
| `72-` / `73-` / `74-` | `ssh-ca`, `sshd`, `pg-ca` | `72-ssh-ca.yaml`, `73-sshd.yaml`, `74-pg-ca.yaml` |
| `80-` / `81-` / `82-` | Loki, Promtail, Grafana provisioning (audit-trail capstone) | `80-loki.yaml`, `81-promtail.yaml`, `82-grafana-provisioning.yaml` |

## Bootstrap Jobs

Two one-shot Jobs auto-generate CA keypairs on first apply:

- `05-ssh-ca-bootstrap.yaml` → `Secret/ssh-ca-key` + `ConfigMap/ssh-ca-pub` (consumed by `ssh-ca` and `sshd`)
- `06-pg-ca-bootstrap.yaml` → `Secret/pg-ca-key` + `ConfigMap/pg-ca-cert` + `Secret/postgres-tls` (consumed by `pg-ca`, and by `postgres` as both server cert and client-cert trust anchor)

Both Jobs are idempotent — re-applies are no-ops once the secrets exist. No manual `ssh-keygen` or `openssl` is needed before the first `kubectl apply`.

## `config-src/` — editable sources for ConfigMaps

A few of the ConfigMaps above embed multi-line config files. The editable sources live in [`config-src/`](config-src/); when you change them, regenerate the corresponding manifest (e.g. `kubectl create cm envoy-config --from-file=envoy.yaml=config-src/envoy.yaml --dry-run=client -o yaml > 30-envoy-config.yaml`).

| Source | Baked into |
|---|---|
| `config-src/envoy.yaml` | `30-envoy-config.yaml` |
| `config-src/pg_hba.conf` | `40-postgres-hba-cm.yaml` |
| `config-src/postgres-init.sql` | `40-postgres-init-cm.yaml` |
| `config-src/realm-export.json` | `11-keycloak-realm-cm.yaml` |

## Cleanup

```bash
kubectl delete ns ams-demo
```

(Or see [`follow-along/99-cleanup.md`](../follow-along/99-cleanup.md) for partial-teardown options and troubleshooting.)
