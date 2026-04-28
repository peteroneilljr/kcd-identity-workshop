# Tests

Full integration test suite for the workshop. Asserts the complete identity → backend matrix end-to-end against a live cluster: HTTP authz, Postgres RLS, Grafana OIDC, SSH cert flow, and direct-psql cert flow.

## Run it

After `kubectl apply -f k8s/` and the deployments are Ready:

```bash
./tests/test-demo.sh
```

The script manages its own port-forwards (Keycloak, Envoy, Grafana, sshd, Postgres), so a clean shell is fine — no manual `kubectl port-forward` required first. It cleans them up on exit.

## What it covers

Five suites, each mapping to a follow-along module:

| Suite | What | Maps to module |
|---|---|---|
| 1 — HTTP authz | Envoy JWT validation, RBAC by `preferred_username`, anon rejection, cross-user 403 | [`02-http-authz.md`](../follow-along/02-http-authz.md) |
| 2 — Postgres RLS | `db-app` SET-ROLE bridge → row-level security per `current_user` | [`04-postgres-rls.md`](../follow-along/04-postgres-rls.md) |
| 3 — Grafana OIDC | Full authorization-code flow against Keycloak; role mapping (alice → Viewer, bob → Admin) | [`01-grafana-oidc.md`](../follow-along/01-grafana-oidc.md) |
| 4 — SSH cert flow | `ssh-ca` JWT-gated cert sign + sshd cert auth + cross-user principal denial | [`03-ssh-certs.md`](../follow-along/03-ssh-certs.md) |
| 5 — Postgres direct psql | `pg-ca` JWT-gated cert sign + Postgres native `cert` auth + cross-user CN rejection + CSR CN-substitution | [`04b-postgres-direct-psql.md`](../follow-along/04b-postgres-direct-psql.md) |

## Preflight

The script checks for required tools before running anything:

```
kubectl curl jq python3 ssh ssh-keygen nc psql openssl
```

Missing any of these → exit 2 with a clear message.

## Output

```
[Suite 1: HTTP authz — Envoy JWT + RBAC]
  ✓ anon /public is 401 (got 401)
  ✓ alice /alice is 200 (got 200)
  ...
[Summary] N passed, 0 failed
```

Failures print red, are listed at the end with their assertion labels, and the script exits non-zero — so it's CI-friendly.

## When to use it

- After a code change to any of the [`docker/`](../docker/) services — confirms backend behaviour didn't drift.
- After a manifest change in [`k8s/`](../k8s/) — confirms the wiring still holds end-to-end.
- As a smoke test before running the workshop live.

For non-test debugging, prefer the interactive walkthrough in [`../demo-script.sh`](../demo-script.sh) (paused, color-coded) or the per-module [`follow-along/`](../follow-along/) commands.
