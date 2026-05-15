# 00 — Setup

Get the cluster running so the rest of the workshop has something to talk to.

[← back to index](README.md) · next: [01-grafana-oidc.md](01-grafana-oidc.md)

## What you'll end up with

10 pods in the `ams-demo` namespace plus a completed bootstrap Job, and four `kubectl port-forward` processes giving you access to:

| local URL | service | what for |
|---|---|---|
| `http://localhost:8180` | Keycloak | get JWTs |
| `http://localhost:8080` | Envoy | gateway to apps + db-app + ssh-ca |
| `http://localhost:3300` | Grafana | OIDC dashboard login |
| `localhost:2222` | sshd | SSH target |

## 1. Apply the manifests

All 14 images this cluster needs — the 8 workshop-specific demo apps plus the 6 third-party base images (alpine, grafana, envoy, keycloak, loki, promtail) — live under `ghcr.io/peteroneilljr/kcd-identity-workshop/*`. Anonymous GHCR pulls aren't rate-limited the way Docker Hub's are, so a room full of attendees on shared NAT can all `apply` at once without tripping a 429.

```bash
kubectl apply -f k8s/
```

Two CA keypairs are auto-generated on first apply by one-shot bootstrap Jobs:

- `k8s/05-ssh-ca-bootstrap.yaml` → `Secret/ssh-ca-key` + `ConfigMap/ssh-ca-pub` (consumed by `ssh-ca` and `sshd`).
- `k8s/06-pg-ca-bootstrap.yaml` → `Secret/pg-ca-key` + `ConfigMap/pg-ca-cert` + `Secret/postgres-tls` (consumed by `pg-ca` for signing, by `postgres` as the trust anchor for client certs and its own server cert).

Both Jobs are idempotent — re-applies are no-ops once the secrets exist. No manual `ssh-keygen` or `openssl` needed.

(If you want to iterate on the demo app code locally, see [`docker/README.md`](../docker/README.md#local-iteration) — re-tag a fresh `docker build` with the GHCR name and `imagePullPolicy: IfNotPresent` will pick it up.)

## 2. Wait for everything Ready

```bash
kubectl -n ams-demo wait --for=condition=Available --timeout=240s deploy --all
kubectl -n ams-demo get pods,job
```

Expect 12 deployment pods Running + 2 promtail pods (DaemonSet, one per node) + 2 bootstrap Jobs Complete:

```
NAME                          READY   STATUS      RESTARTS   AGE
pod/alice-app-...             1/1     Running     0          ...
pod/bob-app-...               1/1     Running     0          ...
pod/db-app-...                1/1     Running     0          ...
pod/envoy-...                 1/1     Running     0          ...
pod/grafana-...               1/1     Running     0          ...
pod/keycloak-...              1/1     Running     0          ...
pod/loki-...                  1/1     Running     0          ...
pod/pg-ca-...                 1/1     Running     0          ...
pod/pg-ca-bootstrap-...       0/1     Completed   0          ...
pod/postgres-...              1/1     Running     0          ...
pod/promtail-...              1/1     Running     0          ...
pod/public-app-...            1/1     Running     0          ...
pod/ssh-ca-...                1/1     Running     0          ...
pod/ssh-ca-bootstrap-...      0/1     Completed   0          ...
pod/sshd-...                  1/1     Running     0          ...

NAME                         STATUS     COMPLETIONS   DURATION
job.batch/pg-ca-bootstrap    Complete   1/1           ...
job.batch/ssh-ca-bootstrap   Complete   1/1           ...
```

## 3. Open the user-facing ports

```bash
kubectl -n ams-demo port-forward svc/keycloak 8180:8180 &
kubectl -n ams-demo port-forward svc/envoy    8080:8080 &
kubectl -n ams-demo port-forward svc/grafana  3300:3000 &
kubectl -n ams-demo port-forward svc/sshd     2222:22   &
```

These run in the background. To stop them later:

```bash
pkill -f "kubectl.*port-forward"
```

## 4. Sanity-check all four endpoints

```bash
curl -s -o /dev/null -w "kc=%{http_code}\n"    http://localhost:8180/realms/demo
curl -s -o /dev/null -w "envoy=%{http_code}\n" http://localhost:8080/health
curl -s -o /dev/null -w "graf=%{http_code}\n"  http://localhost:3300/api/health
nc -z localhost 2222 && echo "sshd=open"
```

Expect:

```
kc=200
envoy=200
graf=200
sshd=open
```

If any of those fail, jump to [99-cleanup.md → Troubleshooting](99-cleanup.md#troubleshooting).

---

→ Cluster's up. Next: [**01-grafana-oidc.md**](01-grafana-oidc.md) — log into Grafana with Keycloak via OIDC code flow. This is the foundational identity flow the rest of the workshop builds on.
