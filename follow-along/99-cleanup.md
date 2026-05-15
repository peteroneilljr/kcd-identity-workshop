# 99 — Cleanup & Troubleshooting

[← back to index](README.md) · prev: [98-experiments.md](98-experiments.md)

## Cleanup

```bash
# Stop port-forwards
pkill -f "kubectl.*port-forward"

# Tear down everything in the cluster
kubectl delete namespace ams-demo
```

The `ams-demo` namespace deletion cascades to all 10 deployments, all services, all configmaps, all secrets, the bootstrap Job, and the SSH CA materials it generated. Running `kubectl apply -f k8s/` again from scratch regenerates the SSH CA and re-imports the Keycloak realm — every rebuild is a clean rebuild.

If you want to reclaim the GHCR-pulled images too:

```bash
docker images --filter=reference='ghcr.io/peteroneilljr/kcd-identity-workshop/*' -q \
  | xargs -r docker rmi
```

## Run the full assertion suite

```bash
./tests/test-demo.sh
```

Dozens of integration checks across all backends — on success the last line is **`ALL … ASSERTIONS PASSED`** with the current total count. This is also what runs on every clean-rebuild verification we did during development.

## Troubleshooting

### `kubectl apply` / `kubectl get` fails: `failed to download openapi` or `connection refused` to `127.0.0.1`

Your kubeconfig points at a Kubernetes API (often minikube on `127.0.0.1:<port>`) that is **not running**. Start **Docker Desktop** (or your container engine), then **`minikube start`** (or equivalent), and confirm **`kubectl cluster-info`** works before applying manifests.

### `minikube start` fails: `docker.sock` / `PROVIDER_DOCKER_VERSION`

The minikube **docker** driver needs a running Docker daemon. Start Docker Desktop and wait until **`docker version`** shows a **Server** section, then retry **`minikube start`**.

### `minikube kubectl --` fails with `connection refused` on a different port than `kubectl cluster-info`

`minikube kubectl` can target a **stale** API address. Use the same **`kubectl`** binary your shell uses after **`minikube start`**, or run **`minikube update-context -p <profile>`**, then retry. Plain **`kubectl`** is sufficient for this workshop.

### `psql: command not found` (module 04b)

Install PostgreSQL client tools. On macOS: **`brew install libpq`**, then put **`…/opt/libpq/bin`** on your **`PATH`** (see [Prerequisites](README.md#prerequisites) in this folder’s index).

### `namespace ams-demo not found`

You skipped Setup. Run `kubectl apply -f k8s/`.

### `401 Jwt is missing`

Either you forgot the `Authorization: Bearer ...` header, or your token expired (5-min lifetime by default). Re-fetch the token.

### `403 access denied`

That's the demo working. alice can't read `/bob`; bob can't read `/alice`. RBAC is doing its job.

### `no jwt identity` from `/db` or `/ssh-ca/sign`

Envoy didn't forward `x-jwt-payload` to the upstream. Check Envoy's logs:

```bash
kubectl -n ams-demo logs deploy/envoy | grep -i jwt | tail -20
```

You'll usually see one of:
- `JWT verification failed: Issuer mismatch` — Keycloak emitted a different `iss` than Envoy expects (re-check `KC_HOSTNAME_URL` on the keycloak deployment).
- `Jwks doesn't have key to match kid` — JWKS cache is stale or Keycloak rotated keys; restart envoy: `kubectl -n ams-demo rollout restart deploy/envoy`.

### Grafana SSO button does nothing

Confirm the pod is actually Ready:

```bash
kubectl -n ams-demo get pod -l app=grafana
```

The container takes ~10s to fully boot OIDC after the readiness probe passes. If you click the button before then, the redirect URL is still the default. Refresh the page.

### SSH `Permission denied (publickey)` for the same-user case (alice→alice)

Your cert may have expired. Check the validity window:

```bash
ssh-keygen -L -f ~/.ssh/keycloak_id-cert.pub | grep Valid
```

If `to` is in the past, re-sign with a fresh token. (See [03-ssh-certs.md](03-ssh-certs.md).)

### Pod stuck in `ImagePullBackOff` for any image

Two likely causes:

1. **Mirror packages went private.** The 5 `ghcr.io/peteroneilljr/kcd-identity-workshop/*` packages are public; if any flipped back to private, anonymous cluster pulls fail. Re-set them to public from the [Packages tab on github.com](https://github.com/peteroneilljr?tab=packages).
2. **Transient registry hiccup.** Manually pre-pull the image:
   ```bash
   docker pull ghcr.io/peteroneilljr/kcd-identity-workshop/postgres:16-alpine
   ```
   On Docker Desktop's k8s the image becomes available to the cluster immediately. The kubelet will retry.

### Bootstrap Job stuck

Check the Job's logs:

```bash
kubectl -n ams-demo logs job/ssh-ca-bootstrap
```

If it's still in `ImagePullBackOff` or `ContainerCreating`, the alpine image (used for ssh-keygen + kubectl) failed to pull. Same fix as above.

---

That's it. You've now seen one Keycloak identity reach four heterogeneous backends — HTTP, SQL, dashboard UI, shell — with a different enforcement mechanism at each layer. The mental model — *one identity provider, many enforcement points, each native to its system* — generalizes to any backend you'd care to add: GraphQL, gRPC, S3, Vault, Kubernetes API, you name it. The pattern is the same; the wire-up is what changes.
