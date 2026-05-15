# 98 — Extra experiments

Now that the four backends are working and you've seen identity flow through each one, here are some bonus experiments that probe the *edges* of the security model — token expiration, tamper detection, cross-cutting access patterns, and CA rotation. Each is short and self-contained.

These all run against the same cluster you've been using; nothing extra to set up. After this, head to [99-cleanup.md](99-cleanup.md) to tear down.

[← back to index](README.md) · prev: [06-grafana-audit.md](06-grafana-audit.md) · next: [99-cleanup.md](99-cleanup.md)

## Token expiration

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

Envoy's `jwt_authn` filter checks the `exp` claim on every request — there's no in-memory session state to expire separately. Short-lived tokens *are* the revocation mechanism.

## Tampered token

Corrupt the JWT’s **signature** segment (third dot-separated part) so the header + payload no longer match the signature:

```bash
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

FAKE=$(printf '%s' "$TOKEN" | python3 -c "import sys; t=sys.stdin.read().strip(); p=t.split('.'); assert len(p)==3; s=p[2]; p[2]=s[:8]+('X' if len(s)>8 else 'bad')+s[9:]; print('.'.join(p))")
curl -i -H "Authorization: Bearer $FAKE" http://localhost:8080/alice     # 401, signature invalid
```

This uses **Python** so it works in **zsh** and **bash** (bash-style `${TOKEN:0:50}` slicing is not portable). The signature covers the header + payload, so tampering the signature invalidates the JWT. Even a forged payload would fail verification before RBAC runs.

## Cross-cutting access matrix as a one-liner

Confirm the per-user, per-route access pattern across all the HTTP endpoints in one go:

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

If you swap usernames or add a path, the matrix updates automatically — useful to verify changes to envoy.yaml's RBAC policies.

## Rotate the SSH CA without redeploying anything else

Rotate the SSH CA's keypair and force all currently-issued user certs to stop working — exactly what you'd do in a real-world CA-rotation incident:

```bash
kubectl -n ams-demo delete secret ssh-ca-key configmap ssh-ca-pub
kubectl -n ams-demo delete job ssh-ca-bootstrap
kubectl apply -f k8s/05-ssh-ca-bootstrap.yaml
kubectl -n ams-demo wait --for=condition=Complete job/ssh-ca-bootstrap --timeout=60s
kubectl -n ams-demo rollout restart deploy/sshd deploy/ssh-ca
```

The CA pubkey embedded in `sshd` changed, so previously-issued certs are no longer trusted. Re-sign with `/ssh-ca/sign` and re-ssh. This is exactly what real-world SSH CA key rotation looks like — no application changes needed, just regenerate + restart the consumers.

If you want a *no-downtime* rotation, the production pattern is to have sshd trust *both* old and new CA pubkeys (`TrustedUserCAKeys` accepts multiple lines), wait for old certs to expire naturally, then remove the old pubkey from sshd's trust list.

---

→ Done playing? Head to [**99-cleanup.md**](99-cleanup.md) to tear it all down.
