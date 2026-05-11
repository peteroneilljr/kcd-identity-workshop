# Thanks for following along! 

Here are some parting notes and questions to help you continue to learn.

## Generalizing: where else this pattern shows up

The bridge-to-protocol-native pattern is everywhere once you start looking. A non-exhaustive map:

| You want… | Bridge / native | What the bridge does |
|---|---|---|
| AWS access from OIDC identity | AWS STS `AssumeRoleWithWebIdentity` | Trades JWT for AWS access keys (15min–12h) |
| kubectl access from OIDC | kubectl OIDC auth provider | Refreshes ID token, sends as bearer to k8s API |
| GitHub Actions → AWS | GitHub OIDC provider + IAM role | Action's JWT → STS session, no long-lived secrets in repo |
| Vault dynamic creds | Vault `kv` + dynamic backends | OIDC login → Vault token → DB user/SSH OTP/AWS keys/etc. |
| Workload identity in k8s | ServiceAccount projected JWT + cloud OIDC | Pod's SA token → IAM/Azure AD/GCP SA, no static creds |
| SSH bastion access | Teleport / smallstep / Vault SSH | OIDC login → SSH cert (this demo's pattern) |
| Database access | HashiCorp Boundary, this demo's pattern | OIDC login → DB user / SET ROLE |
| Slack notifications from a CI job | Slack tokens | (Less common; usually long-lived bot tokens) |
| Snowflake from BI tool | OAuth2 with Snowflake | Native Snowflake OIDC |

Notice the recurring shape: **federated identity at the edge → short-lived protocol-native credential at the resource**. The bridge is sometimes a separate service (this demo's `db-app`, `ssh-ca`), sometimes a feature of the IdP itself (AWS IAM Identity Center), sometimes a feature of the resource (Vault).

## Choosing a pattern for a new backend

When you add a new backend to this kind of system, the question is "which of the four patterns applies?" Answering it is mostly mechanical:

1. **Is this an HTTP service you control or front-end with a proxy?**
   - Yes → Pattern A. Wire it behind Envoy. Same `jwt_authn` + `rbac` config that's already there.

2. **Is this a UI-driven tool that supports OIDC out of the box?**
   - Yes → Pattern C. Register an OIDC client in Keycloak. Configure the tool. Done.

3. **Does this system have a native concept of "act as user X" via a credential it understands (DB role, S3 IAM role, k8s SA token)?**
   - Yes → Pattern B. Build a bridge service that takes the JWT and obtains the system's native credential, then uses it to fulfill the request.

4. **Does this system speak a non-HTTP protocol with its own PKI/cert auth (SSH, mTLS, X.509 client auth)?**
   - Yes → Pattern D. Stand up a CA service that signs short-lived credentials from JWTs.

5. **None of the above?**
   - You're either looking at a system that wasn't designed for federated auth (IRC, raw SMTP, FTP), or you need to invent a custom pattern. Most of the time when you think "none of the above," it's actually Pattern B and you haven't found the system's native impersonation primitive yet.

## Anti-patterns

Things that look like identity-aware access but aren't:

### Sharing service-account credentials

"The app authenticates to Keycloak as the end user, then connects to Postgres as `app_user`, and queries with `WHERE owner_id = $jwt_sub`." This is application-layer authorization, not DB-layer. A SQL injection or app bug bypasses it. The DB sees only `app_user`. *No identity reaches the data layer.*

### Long-lived credentials with audit logs

"We log who triggered each action, so we can audit it later." Audit isn't enforcement — by the time you're reading the log, the action already happened. Identity-aware access *prevents* the cross-user action; audit is what you do after.

### "We use OIDC at the front door" alone

If alice can sign in but the backend uses a shared service account to talk to S3/Postgres/Redis, alice's identity is dropped at the first internal hop. The resource sees only the service account; per-user enforcement is impossible at the resource layer.

### Roles-as-identities

Granting permissions to roles like `read_only` or `admin` instead of usernames means the audit log shows what role acted, not what person. Per-user RBAC requires `principal == "alice"`, not `principal in role "engineer"`. (Roles are useful as *additional* signal, not as the primary identity unit.)

### Bearer tokens in URLs or query params

`/api/data?token=eyJhbGc...` ends up in web-server logs, browser history, referrer headers. Always pass JWTs in the `Authorization: Bearer` header (or short-lived cookies for browser sessions).

### Forever-cached JWKS

If your gateway caches Keycloak's JWKS but never refreshes, key rotation breaks every request silently. Envoy's `cache_duration` is set to 5 minutes in this demo for that reason — short enough to pick up rotation, long enough to avoid hammering the IdP.

## Production hardening checklist

For each backend integration, work through:

**Authentication:**
- [ ] Bearer JWT or browser session?
- [ ] If bearer: token validity short enough? (5-15 min for direct, longer with refresh tokens.)
- [ ] If browser session: secure, httpOnly, samesite cookie, CSRF protection.

**Authorization:**
- [ ] Coarse layer (e.g., gateway RBAC by username) and fine layer (e.g., row-level security in DB)?
- [ ] Default deny everywhere?
- [ ] Fail-closed if upstream is unreachable?

**Crypto:**
- [ ] TLS at every hop. The demo is HTTP-only for simplicity; production must be HTTPS.
- [ ] JWT signed with RS256 or ES256 (asymmetric — gateway has the public key only).
- [ ] JWKS rotated periodically; gateway picks up rotation within `cache_duration`.

**Audit:**
- [ ] Every access decision logged with: user, action, resource, decision, timestamp.
- [ ] Logs go to a SIEM, not just stdout.
- [ ] Failed-auth attempts trigger alerts above some threshold.

**Operational:**
- [ ] Bridge services scale horizontally. (`db-app`, `ssh-ca` are stateless — scale by replicas.)
- [ ] CA private keys stored in HSM or sealed Secret, not plain k8s Secret.
- [ ] Revocation: rely on short validity, not revocation lists, where possible.
- [ ] Rotation runbook exists for: IdP signing keys, CA keys, client secrets.

---

## Further reading

- [OAuth2.0 Security Best Current Practice](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-security-topics) — IETF
- [NIST Zero Trust Architecture (SP 800-207)](https://csrc.nist.gov/publications/detail/sp/800-207/final)
- [Google BeyondCorp papers](https://research.google/pubs/?team=beyondcorp) — the canonical zero-trust literature
- [HashiCorp Vault: secrets engines architecture](https://developer.hashicorp.com/vault/docs/secrets) — many of these are pattern-D bridges
- [GitHub Actions OIDC](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect) — pattern B/D for CI
- This workshop's other docs:
  - [REVERSE-PROXY.md](REVERSE-PROXY.md) — pattern A in depth
  - [POSTGRES-RLS.md](POSTGRES-RLS.md) — pattern B in depth
  - [SSH-CERTIFICATES.md](SSH-CERTIFICATES.md) — pattern D in depth
  - [OAUTH-OIDC.md](OAUTH-OIDC.md) — the OIDC layer that makes pattern C possible
