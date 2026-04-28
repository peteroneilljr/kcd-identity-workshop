# 00 — Setup

Get the cluster running so the rest of the workshop has something to talk to.

[← back to index](README.md) · next: [01-http-authz.md](01-http-authz.md)

## What you'll end up with

10 pods in the `ams-demo` namespace plus a completed bootstrap Job, and four `kubectl port-forward` processes giving you access to:

| local URL | service | what for |
|---|---|---|
| `http://localhost:8180` | Keycloak | get JWTs |
| `http://localhost:8080` | Envoy | gateway to apps + db-app + ssh-ca |
| `http://localhost:3300` | Grafana | OIDC dashboard login |
| `localhost:2222` | sshd | SSH target |

## 1. Build the local app images

The 6 demo-* images are built from this repo. Docker Desktop's k8s shares the docker daemon's image cache automatically; on plain `kind`, follow each build with `kind load docker-image <tag>`.

```bash
docker build -t demo-public-app:k8s   ./public-app
docker build -t demo-alice-app:k8s    ./alice-app
docker build -t demo-bob-app:k8s      ./bob-app
docker build -t demo-db-app:k8s       ./db-app
docker build -t demo-ssh-ca-app:k8s   ./ssh-ca-app
docker build -t demo-sshd:k8s         ./sshd-app
```

The 5 third-party base images (alpine, postgres, grafana, envoy, keycloak) are *not* built locally — the cluster pulls them from `ghcr.io/peteroneilljr/kcd-identity-workshop/*` (a workshop-friendly mirror that bypasses Docker Hub rate limits).

## 2. Apply the manifests

```bash
kubectl apply -f k8s/
```

The SSH CA keypair is auto-generated on first apply by a one-shot bootstrap Job (`k8s/05-ssh-ca-bootstrap.yaml`). The Job creates `Secret/ssh-ca-key` and `ConfigMap/ssh-ca-pub`, which `ssh-ca` and `sshd` Deployments mount. No manual `ssh-keygen` needed.

## 3. Wait for everything Ready

```bash
kubectl -n ams-demo wait --for=condition=Available --timeout=240s deploy --all
kubectl -n ams-demo get pods,job
```

Expect 10 pods Running + bootstrap Job Complete:

```
NAME                          READY   STATUS      RESTARTS   AGE
pod/alice-app-...             1/1     Running     0          ...
pod/bob-app-...               1/1     Running     0          ...
pod/db-app-...                1/1     Running     0          ...
pod/envoy-...                 1/1     Running     0          ...
pod/grafana-...               1/1     Running     0          ...
pod/keycloak-...              1/1     Running     0          ...
pod/postgres-...              1/1     Running     0          ...
pod/public-app-...            1/1     Running     0          ...
pod/ssh-ca-...                1/1     Running     0          ...
pod/ssh-ca-bootstrap-...      0/1     Completed   0          ...
pod/sshd-...                  1/1     Running     0          ...

NAME                         STATUS     COMPLETIONS   DURATION
job.batch/ssh-ca-bootstrap   Complete   1/1           ...
```

## 4. Open the user-facing ports

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

## 5. Sanity-check all four endpoints

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

→ Cluster's up. Next: [**01-http-authz.md**](01-http-authz.md) — see Envoy authorize HTTP requests by JWT identity.
