# SSH Certificate Authentication

This document explains how SSH user certificates work, how the demo uses them to bridge a Keycloak identity into a shell session, and why this pattern beats long-lived public keys for any setup with more than a handful of users.

## Table of Contents

1. [Public-key auth: the baseline](#public-key-auth-the-baseline)
2. [The scaling problem with `authorized_keys`](#the-scaling-problem-with-authorized_keys)
3. [SSH certificates: signed assertions about a public key](#ssh-certificates-signed-assertions-about-a-public-key)
4. [Anatomy of an SSH certificate](#anatomy-of-an-ssh-certificate)
5. [`TrustedUserCAKeys` — sshd trusts a CA, not individual keys](#trustedusercakeys--sshd-trusts-a-ca-not-individual-keys)
6. [`AuthorizedPrincipalsFile` — principal-to-user mapping](#authorizedprincipalsfile--principal-to-user-mapping)
7. [`AuthorizedKeysFile=none` — closing the back door](#authorizedkeysfilenone--closing-the-back-door)
8. [Short validity beats revocation lists](#short-validity-beats-revocation-lists)
9. [The signing service: `ssh-ca` in this demo](#the-signing-service-ssh-ca-in-this-demo)
10. [End-to-end request flow](#end-to-end-request-flow)
11. [What this design protects against](#what-this-design-protects-against)
12. [Production considerations](#production-considerations)

---

## Public-key auth: the baseline

Standard SSH public-key authentication works like this:

1. The user has a keypair: `id_ed25519` (private, never leaves the laptop) and `id_ed25519.pub` (public, shared).
2. The server-side admin appends the public key to `/home/<user>/.ssh/authorized_keys` on the target server.
3. When the user runs `ssh user@host`, the SSH client offers the public key. sshd reads `authorized_keys`, sees a match, sends a challenge encrypted with the public key. The client decrypts it with the private key and proves possession.
4. sshd lets the user in.

The trust statement is: *"The owner of this private key is allowed to log in as `user` on this host."*

That statement is recorded by the file `/home/user/.ssh/authorized_keys` containing one line per allowed key.

## The scaling problem with `authorized_keys`

The `authorized_keys` model has well-known issues:

**Adding a user requires touching every server.** Five servers and a new engineer? Five `authorized_keys` edits, ideally automated. Five hundred servers? You'd better have configuration management.

**Removing a user requires touching every server.** Worse than adding, because a missed server is an active security incident. The departing engineer still has shell access until the last server is updated.

**Keys are typically long-lived.** Once a key is in `authorized_keys`, it's there until someone explicitly removes it. Keys generated 5 years ago and never rotated are common. A laptop stolen years ago might still have working credentials on prod.

**No identity binding.** `authorized_keys` says "this *key* can log in." It says nothing about *who* the key belongs to. If two engineers share a key, you can't tell from the auth log which one logged in.

**No expiration.** sshd doesn't know when a key was added, doesn't know when it should stop working, doesn't have a way to "trust this key for the next 8 hours."

These issues compound. Bigger fleet × longer key lifetimes × no identity binding = an audit nightmare.

## SSH certificates: signed assertions about a public key

SSH certificates (introduced in OpenSSH 5.4, 2010) replace the trust statement with a delegation:

- Instead of *"this key can log in,"* the server's policy becomes *"any key signed by this CA can log in."*
- The CA owns the actual decision of *who*, *as whom*, and *for how long*.
- The server doesn't need to know anything about specific users — just the CA's public key.

The flow:

```
1. Client                 ssh-keygen -t ed25519 -f id   (keypair, do once)
                                  │
                                  ▼ id.pub
2. CA service             Receives id.pub + identity claim (e.g., from JWT).
                          ssh-keygen -s ca -I <id> -n <principal> -V +15m id.pub
                                  │
                                  ▼ id-cert.pub
3. Client                 Has id (private), id.pub (public), id-cert.pub (signed cert).
                          ssh -i id user@host         (cert auto-detected)
                                  │
                                  ▼
4. sshd                   Receives cert during handshake. Verifies:
                            - signed by trusted CA?
                            - cert.principal in this user's allow-list?
                            - cert.valid_after ≤ now ≤ cert.valid_before?
                          If all yes → grant.
```

The user's keypair is just *cryptographic material* — it doesn't carry authorization on its own. The cert binds it (temporarily) to an identity that the CA vouches for.

## Anatomy of an SSH certificate

You can inspect a cert with `ssh-keygen -L -f id-cert.pub`:

```
id-cert.pub:
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Public key: ED25519-CERT SHA256:abc123...
        Signing CA: ED25519 SHA256:def456...    (using ssh-ed25519)
        Key ID: "alice-1714323456-7e9a"
        Serial: 0
        Valid: from 2026-04-28T10:00 to 2026-04-28T10:15
        Principals:
                alice
        Critical Options: (none)
        Extensions:
                permit-X11-forwarding
                permit-agent-forwarding
                permit-port-forwarding
                permit-pty
                permit-user-rc
```

Eight fields matter for our purposes:

| Field | Purpose |
|---|---|
| **Type** | `user certificate` (vs `host certificate`, which authenticates servers to clients) |
| **Public key** | The user's pubkey — what's actually being asserted about |
| **Signing CA** | Public key fingerprint of the CA that signed this. sshd checks against `TrustedUserCAKeys`. |
| **Key ID** | Free-text, audit log only. Demo sets it to `<user>-<timestamp>-<random>`. |
| **Serial** | For revocation lists. Demo doesn't use, so it's 0. |
| **Valid from/to** | Time window when the cert is honored. Demo uses 15 minutes. |
| **Principals** | List of identities the cert can claim. Demo sets to `<preferred_username>`. |
| **Extensions** | Capabilities granted (port forwarding, ptys, etc.) |

The CA's signature covers all of these — you can't tamper with the principal list or extend the validity without re-signing, which only the CA can do.

## `TrustedUserCAKeys` — sshd trusts a CA, not individual keys

In `/etc/ssh/sshd_config`:

```
TrustedUserCAKeys /etc/ssh/ca.pub
```

`ca.pub` contains the CA's public key (one or more, one per line). When a cert arrives during the SSH handshake, sshd:

1. Reads the cert's `Signing CA` field.
2. Looks for a matching CA pubkey in `TrustedUserCAKeys`.
3. If found, verifies the cert's signature against that CA pubkey.
4. If not found, the cert is treated as untrusted — sshd falls back to `authorized_keys` (which we'll disable in a moment).

In the demo, `ca.pub` is generated by the bootstrap Job (`k8s/05-ssh-ca-bootstrap.yaml`) and mounted into the sshd pod via a ConfigMap (`ssh-ca-pub`):

```yaml
volumeMounts:
  - name: ca-pub
    mountPath: /etc/ssh/ca.pub
    subPath: ca.pub
    readOnly: true
volumes:
  - name: ca-pub
    configMap:
      name: ssh-ca-pub
```

If you rotate the CA, you re-bake the ConfigMap and bounce sshd. Old certs (signed by the old CA) stop working immediately on the new sshd. New certs (signed by the new CA) work.

**Crucially**, the sshd pod does not need to know about specific users. It just trusts the CA. Adding `charlie` later requires no sshd restart, no config change, no `authorized_keys` edit on the server — only a new unix account + principals file (covered next).

## `AuthorizedPrincipalsFile` — principal-to-user mapping

A cert's `Principals` list says *what identities this cert can claim*. But sshd still needs to map "claimed identity = alice" to "unix user = alice" — and you might want different mappings on different hosts (e.g., this cert for `alice` can log in as `alice`, but on the bastion host it can also log in as `ubuntu`).

That mapping lives in `AuthorizedPrincipalsFile`:

```
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
```

The `%u` token expands to the *target unix username* — i.e., the user the SSH client is trying to log in as (from `ssh alice@host` → `%u = alice`). sshd reads `/etc/ssh/auth_principals/alice` and gets a list of principals that are authorized to log in as alice.

In the demo's sshd image:

```
/etc/ssh/auth_principals/alice  → contains the line "alice"
/etc/ssh/auth_principals/bob    → contains the line "bob"
```

So:

- alice's cert (principal=alice) → `ssh alice@host` → sshd checks `/etc/ssh/auth_principals/alice` → contains `alice` → match → granted.
- alice's cert (principal=alice) → `ssh bob@host` → sshd checks `/etc/ssh/auth_principals/bob` → contains `bob`, not `alice` → no match → **denied**.

This is the layer that prevents cross-user impersonation. Even though alice's cert is technically valid (signed by the trusted CA, in its validity window), it can't be used to log in as bob because the *server* keeps a per-user mapping of which principals are allowed to log in as which unix user.

If you wanted a "team" account where multiple identities could log in as `ubuntu`:

```
/etc/ssh/auth_principals/ubuntu  → 
  alice
  bob
  charlie
```

Now any cert with a principal in that list can `ssh ubuntu@host`. Identity is preserved (audit log shows who logged in), but the unix account is shared.

## `AuthorizedKeysFile=none` — closing the back door

By default, sshd checks `~/.ssh/authorized_keys` for a public key match *in addition to* checking certs. That's a fallback path that defeats the cert-only model — anyone with a stale key in `authorized_keys` could still log in.

The demo's sshd_config disables it entirely:

```
AuthorizedKeysFile none
```

Now the only auth path is cert-based. There's no per-user `authorized_keys` to keep in sync, no laptop key from 5 years ago that still works, no possibility of a bypass.

Combined with `PasswordAuthentication no` and `PermitRootLogin no`, the entire authentication surface reduces to: *"You have a CA-signed certificate with a principal that maps to this unix account, or you don't get in."*

## Short validity beats revocation lists

Long-lived credentials need a way to revoke them. SSH supports two revocation mechanisms:

- **CA revocation list** (`RevokedKeys`): a file listing keys/certs that should not be honored, by serial number or fingerprint.
- **OCSP-style checking**: not supported in stock OpenSSH; some forks add it.

Both have the same problem as `authorized_keys`: distributing the revocation list to every server, keeping it fresh, ensuring it's actually checked. A revoked key on a server that's behind on its config sync is still a working key.

Short-lived certs sidestep this. The demo issues 15-minute certs:

```
ssh-keygen -s ca -I "${certId}" -n "${user}" -V +15m "${userKey}"
```

Properties:

- A stolen cert is worthless within 15 minutes — no revocation infra needed.
- A revoked Keycloak user can't refresh their cert (Envoy + ssh-ca will reject the JWT). Within 15 minutes, all their existing certs expire.
- "Logout" is implicit — stop signing, expiry handles the rest.

Tradeoff: users have to re-sign frequently. For interactive sessions this is invisible (sign once, ssh, work, session is fine even if cert expires mid-session — the cert is only checked at handshake). For automated batch jobs, you'd extend validity or wire up auto-refresh.

15 minutes is a balance. AWS STS uses 15 minutes to 12 hours depending on workload. Vault SSH OTP defaults to 30 days (much longer, but with explicit revocation). Pick a window that matches your threat model.

## The signing service: `ssh-ca` in this demo

`docker/ssh-ca-app/server.js` is ~80 lines of Node. The signing path:

```js
app.post('/sign', async (req, res) => {
  const user = jwtUsername(req);                           // from x-jwt-payload
  if (!user) return res.status(401).json({...});
  if (!ALLOWED.has(user)) return res.status(403).json({...});

  const pubkey = req.body.trim();
  if (!SSH_PUBKEY_RE.test(pubkey)) return res.status(400);

  const dir = await fs.mkdtemp(...);
  await fs.writeFile(`${dir}/user.pub`, pubkey + '\n');

  await execFile('ssh-keygen', [
    '-s', CA_KEY_PATH,
    '-I', certId,                                          // audit ID
    '-n', user,                                            // principal = JWT user
    '-V', '+15m',                                          // validity
    `${dir}/user.pub`,
  ]);

  const cert = await fs.readFile(`${dir}/user-cert.pub`, 'utf8');
  res.type('text/plain').send(cert);
});
```

Three security-critical decisions visible in this code:

1. **Identity comes from the JWT, not the request body.** The user can pass any pubkey, but they can't pass the principal — it's set strictly from `preferred_username` in the (already-Envoy-validated) JWT.
2. **Allowlist on identities** (`ALLOWED = new Set(['alice', 'bob'])`). Even if Envoy somehow forwarded an unexpected username, the signer refuses.
3. **Public key validation** (regex). Defends against shell injection via the pubkey arg — only well-formed `ssh-ed25519`/`ssh-rsa`/`ecdsa-*` lines are accepted.

The CA private key is mounted into the pod via a Kubernetes Secret with `defaultMode: 0440` and `fsGroup: 1001` matching the unprivileged Node user. The signer process can read it; nothing else in the pod (no other user, no other process volume mount) can.

## End-to-end request flow

```
0. (one-time)
   User                 ssh-keygen -t ed25519 -f ~/.ssh/keycloak_id

1. User                 curl POST .../token (username/password) → JWT
                                  │
                                  ▼
2. User                 curl POST /ssh-ca/sign + JWT bearer + ~/.ssh/keycloak_id.pub
                                  │
                                  ▼
3. Envoy: jwt_authn     Verify JWT. Decode → metadata. Forward x-jwt-payload.
4. Envoy: rbac          /ssh-ca → any authenticated → ALLOW.
                                  │
                                  ▼
5. ssh-ca               Decode x-jwt-payload → preferred_username = "alice".
                        Allowlist check.
                        Validate pubkey shape.
                        ssh-keygen -s /etc/ssh-ca/ca -I alice-... -n alice -V +15m /tmp/.../user.pub
                        Read /tmp/.../user-cert.pub → return.
                                  │
                                  ▼
6. User                 ~/.ssh/keycloak_id-cert.pub  (cert beside the key)
                        ssh -i ~/.ssh/keycloak_id -p 2222 alice@localhost
                        ssh client auto-attaches *-cert.pub to handshake.
                                  │
                                  ▼
7. sshd                 Receives cert during pubkey auth.
                        Verifies signature against /etc/ssh/ca.pub (TrustedUserCAKeys).
                        Cert principal = "alice".
                        Reads /etc/ssh/auth_principals/alice → "alice" matches.
                        Cert valid time window: yes.
                        AuthorizedKeysFile=none, so no fallback check.
                        → Grant.
                                  │
                                  ▼
8. User                 Shell session as alice.
```

Same private key, different identity per signing — control is in *which JWT was used to sign*. The private key never moves.

## What this design protects against

### Cross-user impersonation (alice's cert as bob)

Blocked at sshd's principals check. The cert is technically valid (signed by trusted CA, in its window), but its principal `alice` isn't in `/etc/ssh/auth_principals/bob`. *No SQL or HTTP layer involved* — this is sshd's own logic.

### Stolen cert

Worthless within 15 minutes by design. No revocation list needed. (You could add one for paranoid environments — `RevokedKeys` directive — but for short windows it's overkill.)

### Stolen private key

Useless without a current cert. The private key alone gets `Permission denied (publickey)` because `AuthorizedKeysFile=none`. The attacker would need to also obtain a current cert, which requires a current Keycloak credential.

### Compromised CA private key

This is the worst case for the cert model. An attacker with the CA private key can sign arbitrary certs for any principal, valid for any duration — they own all SSH access. Mitigations:

- Mount the key with strict perms (Secret + `fsGroup`, mode 0440).
- Rotate periodically: regenerate, restart sshd with new `ca.pub`.
- For high-stakes setups, run the CA on an HSM or use Vault's SSH secrets engine with a hardware-backed signing key.
- Audit Job logs: every sign should produce a Key ID logged somewhere.

### Shell injection through pubkey input

The signer treats the pubkey as a file (writes it, then passes the file path to `ssh-keygen`). The pubkey content is regex-validated before the file write. `ssh-keygen` parses the file itself; we don't pass any of its content as a shell argument. No injection surface.

### Forged JWT identity

Caught upstream by Envoy's `jwt_authn` filter — never reaches the signer. If the JWT's signature doesn't verify against Keycloak's JWKS, the request gets 401 at Envoy and `ssh-ca` never runs.

## Production considerations

### Cert validity window

15 minutes is good for interactive workshop use. Real production would tune this:

- Long-running batch jobs: maybe 24h, with explicit revocation.
- Interactive ops: 15 min – 1 hour, force re-auth on expiry.
- High-security envs (PCI, etc.): consider OTP-style ephemeral certs that are signed per-session.

### Host certificates

This demo focuses on user certs (authenticating clients to servers). The reverse — host certs (authenticating servers to clients) — is also valuable. Without it, users get the standard `Are you sure you want to continue connecting? (yes/no)` prompt and learn to mash yes, defeating MITM protection. Host certs let your CA also sign each host's pubkey, and clients with `@cert-authority * <ca pubkey>` in `~/.ssh/known_hosts` trust any host signed by your CA.

### Audit logging

The cert's `Key ID` field is free-form and shows up in `/var/log/auth.log`:

```
Accepted publickey for alice from 1.2.3.4: ED25519-CERT SHA256:... ID alice-1714323456-7e9a (serial 0) CA ED25519 SHA256:...
```

A useful pattern is to include the JWT's `jti` (token ID) in the Key ID, so you can correlate "who logged in" with "which Keycloak session." For audit, also log every signing in `ssh-ca`'s structured logs.

### Bastion hosts and ProxyJump

Cert-based auth works with bastions naturally. Configure `~/.ssh/config`:

```
Host *.internal
  ProxyJump bastion
  IdentityFile ~/.ssh/keycloak_id
  CertificateFile ~/.ssh/keycloak_id-cert.pub
```

The cert's principal needs to be in `auth_principals` on both the bastion and the target. Sometimes you have one principal that opens the bastion and another that opens the target, requiring two signing operations or wider principal lists.

### CA key rotation

To rotate without downtime: have sshd trust *both* old and new CA pubkeys (`TrustedUserCAKeys` accepts multiple lines), start signing with the new key, wait for old certs to expire, remove the old pubkey from sshd's trust list, bounce sshd. Zero-downtime if planned correctly.

### TLS for the signing endpoint

In this demo, `/ssh-ca/sign` is HTTP-only, accessed via port-forward on the loopback. In production, this endpoint MUST be over TLS — the JWT in the Authorization header is bearer-style and can be replayed if observed. Same goes for the returned cert (it's pseudo-public, but its existence reveals the signing event).

### Multi-tenancy

For multiple teams sharing a CA: include team in the principal name (`team-platform-alice`), match via prefix in `AuthorizedPrincipalsFile`. Or run separate CAs per team and have sshd trust multiple via `TrustedUserCAKeys`.

---

## Further reading

- [OpenSSH certificate format](https://man.openbsd.org/ssh-keygen#CERTIFICATES) — `ssh-keygen(1)` `CERTIFICATES` section
- [`sshd_config` reference](https://man.openbsd.org/sshd_config) — search for `TrustedUserCAKeys`, `AuthorizedPrincipalsFile`, `AuthorizedKeysFile`
- [How Facebook scales SSH](https://engineering.fb.com/2016/09/12/security/scalable-and-secure-access-with-ssh/) — the canonical "why we moved off authorized_keys" article
- [HashiCorp Vault SSH Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/ssh) — production-grade implementation of this pattern
- [Teleport SSH](https://goteleport.com/docs/connect-your-client/tsh/) — same pattern, full product around it
- [smallstep step-ssh](https://smallstep.com/docs/step-ssh) — minimalist CA tooling
- Workshop module: [`follow-along/04-ssh-certs.md`](../follow-along/04-ssh-certs.md) — hands-on commands
