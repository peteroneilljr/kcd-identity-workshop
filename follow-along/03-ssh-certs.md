# 03 — SSH: short-lived certs signed from a JWT

Shell access is gated by an **SSH user certificate** signed at runtime by an in-cluster CA. The pattern: HTTP `POST /ssh-ca/sign` your SSH public key with a Keycloak token; get back a 15-minute SSH cert whose `Principal` is your JWT username; `ssh -i key host` works because sshd trusts the CA's pubkey.

This pattern is what tools like Teleport and HashiCorp Vault's SSH secrets engine do under the hood. Doing it yourself in ~50 lines of node + a few k8s manifests demystifies a lot.

[← back to index](README.md) · prev: [02-http-authz.md](02-http-authz.md) · next: [04-postgres-rls.md](04-postgres-rls.md)

## Prerequisite

[`00-setup.md`](00-setup.md) finished. Quick check the SSH listener is reachable:

```bash
nc -z localhost 2222 && echo "sshd=open"
```

## One-time: a local SSH keypair

This is *your* SSH identity. The CA never sees the private key — only the public half, which it signs.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/keycloak_id -N "" -C "$(whoami)@laptop"
ls ~/.ssh/keycloak_id*
```

Two files: `keycloak_id` (private) and `keycloak_id.pub` (public). The signed certificate that we'll get back lives next to them as `keycloak_id-cert.pub`.

## Sign a cert as alice

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: text/plain" --data-binary @"$HOME/.ssh/keycloak_id.pub" \
  http://localhost:8080/ssh-ca/sign \
  > "$HOME/.ssh/keycloak_id-cert.pub"
```

Inspect what came back:

```bash
ssh-keygen -L -f ~/.ssh/keycloak_id-cert.pub | head -10
```

```
~/.ssh/keycloak_id-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Public key: ED25519-CERT SHA256:...
        Signing CA: ED25519 SHA256:... (using ssh-ed25519)
        Key ID: "alice-1714323456-abcdef12"
        Serial: 0
        Valid: from 2026-04-28T... to 2026-04-28T... (15 min later)
        Principals:
                alice
        Critical Options: (none)
        Extensions:
                permit-pty, permit-user-rc, permit-X11-forwarding, ...
```

`Principals: alice` — that's the moment Keycloak's identity becomes an SSH-layer identity.

## ssh as alice (cert is auto-picked-up next to the key)

```bash
ssh -i ~/.ssh/keycloak_id -p 2222 alice@localhost
```

Inside the session:

```bash
whoami        # alice
hostname      # sshd-...
cat /etc/os-release | head -2
exit
```

OpenSSH automatically sends `keycloak_id-cert.pub` because of its `*-cert.pub` naming convention next to the key. sshd checks the cert was signed by the trusted CA, then checks `principal=alice` against `/etc/ssh/auth_principals/alice` (which contains the line `alice`). Match → in.

## alice's cert is rejected as bob

```bash
ssh -i ~/.ssh/keycloak_id -p 2222 bob@localhost whoami
# Permission denied (publickey).
```

Why: `/etc/ssh/auth_principals/bob` contains only the line `bob`. The cert's principal is `alice`, so sshd refuses *even though the CA signature is valid*. Cross-user impersonation is blocked at the principals layer, not the signature layer.

## Now sign as bob and ssh as bob

```bash
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_BOB" \
  -H "Content-Type: text/plain" --data-binary @"$HOME/.ssh/keycloak_id.pub" \
  http://localhost:8080/ssh-ca/sign \
  > "$HOME/.ssh/keycloak_id-cert.pub"

ssh -i ~/.ssh/keycloak_id -p 2222 bob@localhost whoami   # bob
```

You overwrote `*-cert.pub`; the ssh client picks up the new principal automatically. **Same private key, different identity** — controlled by which Keycloak token you used to sign. The private key never moves.

## Why this matters

Five observations:

1. **No long-lived SSH keys.** The cert expires in 15 minutes. There's nothing to revoke — just stop signing.
2. **No password auth, no naked-key auth.** sshd has `AuthorizedKeysFile=none` and `PasswordAuthentication=no`. The *only* path in is a CA-signed cert with the right principal.
3. **The CA's authority is the JWT.** ssh-ca won't sign without a valid JWT, and the JWT determines the principal. So the chain of trust is: Keycloak password → JWT → SSH cert → shell. Every link is short-lived and verifiable.
4. **Cross-user impersonation is blocked at sshd, not just at Envoy.** Even if you somehow got alice's signed cert, you couldn't use it to log in as bob. sshd does the principal check.
5. **`ssh-ca` is just a tiny HTTP service** behind Envoy — same pattern as `db-app`. The CA private key lives in a Kubernetes Secret and is read-only by the signer process. (Run `kubectl get secret -n ams-demo ssh-ca-key -o yaml` if you want to see how it's mounted.)

This is roughly how Teleport's `tsh ssh` works under the hood. The mental model — *use OIDC to get short-lived signed credentials, then use those for the protocol's native auth* — generalizes to AWS STS (OIDC → AWS access keys), kubectl (OIDC → kubeconfig token), Vault SSH OTP, etc.

---

→ Next: [**04-postgres-rls.md**](04-postgres-rls.md) — same federated identity, bridged into Postgres. [**04**](04-postgres-rls.md) uses **`db-app`** (JWT → `SET ROLE` + RLS over HTTP). [**04b**](04b-postgres-direct-psql.md) adds interactive **`psql`** with a short-lived client cert — the same *OIDC → signed credential → native protocol auth* pattern as SSH above.
