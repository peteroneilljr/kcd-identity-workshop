# 01 — OIDC code flow with Grafana

OIDC (OpenID Connect) is the foundation everything else in this workshop builds on. Before any backend can enforce identity, the user has to *prove* who they are to Keycloak — and the standard browser-driven way to do that is the OIDC authorization code flow.

Grafana is the simplest place to see this in action: click a button, log in, and your Keycloak identity *becomes* Grafana's identity. The rest of the workshop's backends use this same Keycloak identity in different ways — the HTTP gateway will validate JWTs Keycloak issues, db-app will translate them into Postgres roles, ssh-ca will sign them into SSH certs — but the human-facing flow always starts here.

[← back to index](README.md) · prev: [00-setup.md](00-setup.md) · next: [02-http-authz.md](02-http-authz.md)

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

Three observations to carry into the rest of the workshop:

1. **Grafana doesn't need a custom integration.** It speaks OIDC; we just configured one provider. Same pattern works for any OIDC-aware app — Argo CD, GitLab, Vault UI, Kubernetes Dashboard, Sonatype Nexus, etc. When you can plug straight into Keycloak with a few config lines, you do — that's the easiest case.
2. **The JWT you've now obtained is the universal currency for the rest of the workshop.** The next module shows how to fetch the same token directly via curl (without a browser) and present it as a bearer token to an API gateway. After that, you'll see two examples of *bridging* that JWT into systems that don't speak OIDC natively (Postgres and SSH).
3. **Same identity, different role mappings per system.** alice will be `Viewer` here in Grafana but a fully empowered owner of `/alice` and her own DB rows in the next parts. Each system decides what the JWT identity *means* in its own terms — the IdP only attests *who* you are.

---

→ Next: [**02-http-authz.md**](02-http-authz.md) — same identity, this time as a bearer JWT validated by an API gateway on every request.
