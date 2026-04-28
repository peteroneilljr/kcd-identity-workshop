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

If you want to remove the locally-built images too:

```bash
docker rmi demo-public-app:k8s demo-alice-app:k8s demo-bob-app:k8s \
           demo-db-app:k8s demo-ssh-ca-app:k8s demo-sshd:k8s
```

## Run the full assertion suite

```bash
./tests/test-demo.sh
```

25 assertions across all four backends — should print `ALL 25 ASSERTIONS PASSED`. This is also what runs on every clean-rebuild verification we did during development.

## Troubleshooting

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
