# 99 — Cleanup, Troubleshooting, Extra Experiments

[← back to index](README.md) · prev: [04-ssh-certs.md](04-ssh-certs.md)

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

## Extra experiments

### Token expiration

Keycloak access tokens last 5 minutes by default. Watch what happens when one expires:

```bash
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

# Works:
curl -i -H "Authorization: Bearer $TOKEN" http://localhost:8080/alice    # 200

# Wait past expiration, then try again:
sleep 305
curl -i -H "Authorization: Bearer $TOKEN" http://localhost:8080/alice    # 401, exp passed
```

### Tampered token

Modify a few characters in the middle of the token — the signature won't verify:

```bash
FAKE="${TOKEN:0:50}HACKED${TOKEN:56}"
curl -i -H "Authorization: Bearer $FAKE" http://localhost:8080/alice     # 401, signature invalid
```

### Cross-cutting access matrix as a one-liner

```bash
for U in alice bob; do
  T=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
       -d "client_id=demo-client&grant_type=password&username=$U&password=password" | jq -r .access_token)
  for P in /public /alice /bob /db; do
    printf "%-5s %-8s -> %s\n" "$U" "$P" \
      "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" http://localhost:8080$P)"
  done
done
```

Expected:

```
alice /public   -> 200
alice /alice    -> 200
alice /bob      -> 403
alice /db       -> 200
bob   /public   -> 200
bob   /alice    -> 403
bob   /bob      -> 200
bob   /db       -> 200
```

### Rotate the SSH CA without redeploying anything else

```bash
kubectl -n ams-demo delete secret ssh-ca-key configmap ssh-ca-pub
kubectl -n ams-demo delete job ssh-ca-bootstrap
kubectl apply -f k8s/05-ssh-ca-bootstrap.yaml
kubectl -n ams-demo wait --for=condition=Complete job/ssh-ca-bootstrap --timeout=60s
kubectl -n ams-demo rollout restart deploy/sshd deploy/ssh-ca
```

The CA pubkey embedded in `sshd` changed, so previously-issued certs are no longer trusted. Re-sign and re-ssh. This is also exactly what real-world CA key rotation looks like.

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

If `to` is in the past, re-sign with a fresh token. (See [04-ssh-certs.md](04-ssh-certs.md).)

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
