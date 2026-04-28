# 03 — Grafana: OIDC code flow direct to Keycloak

Grafana speaks OIDC natively, so this part is the **opposite** pattern from the previous two: Envoy is **not** in this path at all. Grafana redirects the user's browser to Keycloak, runs the standard OAuth2 authorization-code flow, and uses Keycloak's `realm_access.roles` claim to decide whether the user is a Grafana Admin or Viewer.

[← back to index](README.md) · prev: [02-postgres-rls.md](02-postgres-rls.md) · next: [04-ssh-certs.md](04-ssh-certs.md)

## Prerequisite

[`00-setup.md`](00-setup.md) finished. Confirm Grafana is reachable:

```bash
curl -s http://localhost:3300/api/health | jq .
# { "database": "ok", "version": "11.2.0", "commit": "..." }
```

## Browser flow

1. Open <http://localhost:3300/login> in a browser.
2. Click **Sign in with Keycloak** (large button below the username/password form).
3. You'll be redirected to `http://localhost:8180/realms/demo/protocol/openid-connect/auth?...` — Keycloak's login form.
4. Log in as either:
   - `alice` / `password`
   - `bob` / `password`
5. Keycloak redirects you back to Grafana with a `code` param. Grafana exchanges the code for an ID token and access token, reads claims, creates (on first login) or updates the Grafana user, and drops you in.

You're now signed in as that Keycloak user. First login auto-provisions; subsequent logins update.

## What role you'll get

Grafana maps Keycloak's `realm_access.roles` claim to a Grafana org role using a JMESPath in `60-grafana.yaml`:

```ini
role_attribute_path = contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'
```

So:

| Keycloak user | realm_access.roles | Grafana role |
|---|---|---|
| `alice` | `["user"]` | **Viewer** |
| `bob`   | `["user", "admin"]` | **Admin** |

Sign in as alice → top-right avatar shows "Viewer", Admin menu items are missing. Sign out, sign in as bob → "Admin", everything's available.

## Verify with the API

In the same browser session that just logged in, open:

<http://localhost:3300/api/user>

You should see something like:

```json
{
  "id": 2,
  "email": "alice@demo.local",
  "name": "Alice User",
  "login": "alice",
  "isExternal": true,
  "isExternallySynced": true,
  "authLabels": ["Generic OAuth"],
  ...
}
```

`isExternallySynced: true` and `authLabels: ["Generic OAuth"]` are the proof — Grafana sourced this user from Keycloak rather than its local DB.

And to see the Grafana org role:

<http://localhost:3300/api/user/orgs>

```json
[{ "orgId": 1, "name": "Main Org.", "role": "Viewer" }]
```

Switch users → switch role.

## How the URL split works

Grafana's OIDC config has three URLs that look weird until you understand who's actually fetching each one:

| setting | URL | who hits it |
|---|---|---|
| `auth_url` | `http://localhost:8180/...` | the user's **browser** (port-forwarded) |
| `token_url` | `http://keycloak:8180/...` | the **Grafana pod** (in-cluster DNS) |
| `api_url` | `http://keycloak:8180/...` | the **Grafana pod** (in-cluster DNS) |

The browser only ever sees `localhost:8180` because that's where the port-forward exposes Keycloak. Grafana itself, running inside the cluster, talks to Keycloak via the in-cluster Service DNS `keycloak:8180` — much more direct.

`KC_HOSTNAME_URL=http://localhost:8180` on the Keycloak deployment pins the JWT `iss` claim deterministically regardless of which network path delivered the token endpoint call. `KC_HOSTNAME_STRICT_BACKCHANNEL=false` lets the in-cluster URL work on the back channel.

## Why this matters

Three observations:

1. **Grafana doesn't need a custom integration.** It speaks OIDC; we just configured one provider. Same pattern works for any OIDC-aware app — Argo CD, ArgoCD, GitLab, Vault UI, Kubernetes Dashboard, etc.
2. **No shared secrets between Grafana and the apps.** Grafana has its own client_id + secret with Keycloak. The HTTP apps in the previous parts have nothing to do with Grafana's auth.
3. **Same identity, different role mappings per system.** alice is `Viewer` in Grafana but a fully empowered owner of `/alice` and her own DB rows. Each system decides what the JWT identity *means* in its own terms.

---

→ Next: [**04-ssh-certs.md**](04-ssh-certs.md) — same identity, into the most non-HTTP backend possible: a shell session.
