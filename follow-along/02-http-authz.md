# 02 — HTTP authz: Envoy + JWT + RBAC

In [01](01-grafana-oidc.md) you logged into Grafana via the browser and watched Keycloak hand you back into a session. The token Keycloak issued got consumed by Grafana automatically — you never saw it.

This module pulls the curtain back. We'll fetch a Keycloak access token directly with curl, decode it to see what's inside, and present it as a bearer credential to a different system: an API gateway (Envoy) sitting in front of three HTTP services (`/public`, `/alice`, `/bob`). Envoy validates the JWT on every request and applies an RBAC policy that keys on `preferred_username`. Backends never see anonymous traffic.

[← back to index](README.md) · prev: [01-grafana-oidc.md](01-grafana-oidc.md) · next: [03-ssh-certs.md](03-ssh-certs.md)

## Prerequisite

[`00-setup.md`](00-setup.md) finished. Sanity-check the gateway is reachable:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health   # 200
```

## Anon: every authenticated route is locked

```bash
curl -i http://localhost:8080/public  # 401 — Jwt is missing
curl -i http://localhost:8080/alice   # 401
curl -i http://localhost:8080/bob     # 401
curl -i http://localhost:8080/health  # 200 — the only public route
```

Envoy's `jwt_authn` filter rejects anything missing or with an invalid bearer. Backends never get the request — Envoy short-circuits.

## Get a token and inspect what's in it

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)
```

Decode the payload (it's a base64-encoded JSON middle segment of the JWT):

```bash
PAYLOAD=$(echo "$TOKEN_ALICE" | cut -d. -f2)
case $((${#PAYLOAD} % 4)) in 2) PAYLOAD="${PAYLOAD}==" ;; 3) PAYLOAD="${PAYLOAD}=" ;; esac
echo "$PAYLOAD" | base64 -d 2>/dev/null \
  | jq '{username: .preferred_username, email, roles: .realm_access.roles, exp}'
```

Expect:

```json
{
  "username": "alice",
  "email": "alice@demo.local",
  "roles": ["user"],
  "exp": 1234567890
}
```

The `preferred_username` claim is what Envoy's RBAC filter will key on.

## alice can hit `/public` and `/alice`, but not `/bob`

```bash
curl -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/public \
  | jq '{authenticated_user, jwt_claims}'

curl -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/alice \
  | jq '{authenticated_user, jwt_claims}'

curl -i -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/bob   # 403
```

The 403 is the moment that matters: alice has a *valid* token, but the RBAC policy `allow-bob-only` requires `preferred_username == "bob"`. Authentication ≠ Authorization.

### Note on `authenticated_user` in JSON responses

The demo apps may return **`"authenticated_user": "anonymous"`** even when **`jwt_claims`** shows the correct Keycloak user. They populate `authenticated_user` from the **`x-forwarded-user`** header, which this stack’s Envoy config does not set; identity for the workshop is carried in Envoy’s **`x-jwt-payload`** header instead (surfaced as **`jwt_claims`** in JSON). Envoy RBAC and the **`403`** above still key off the verified JWT metadata — trust those and **`jwt_claims`**, not `authenticated_user`, here.

## bob is the mirror image — and admin role doesn't override it

```bash
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r .access_token)

curl    -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/public  # 200
curl    -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/bob     # 200
curl -i -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/alice   # 403
```

Bob has the `admin` realm role, but the RBAC policies key on **identity**, not roles. `admin` doesn't unlock alice's app.

## What's actually in Envoy's config

The relevant policies (excerpt from `k8s/config-src/envoy.yaml`):

```yaml
"allow-alice-only":
  permissions: [path prefix: /alice]
  principals:
    - metadata: { key: jwt_payload.preferred_username, value: "alice" }

"allow-bob-only":
  permissions: [path prefix: /bob]
  principals:
    - metadata: { key: jwt_payload.preferred_username, value: "bob" }

"allow-public":
  permissions: [path prefix: /public OR /health OR /db OR /ssh-ca]
  principals: [any: true]   # any authenticated user
```

There's no `admin` clause anywhere. Roles aren't the trust unit here — usernames are.

## Why this matters

Envoy is the choke point for a fleet of backend services that don't have to know anything about authentication. They just receive HTTP requests pre-authorized by Envoy, plus a `x-jwt-payload` header containing the verified claims if they want to *use* the identity (which is what `db-app`, `ssh-ca`, and `pg-ca` do — covered in the next modules).

---

→ Next: [**03-ssh-certs.md**](03-ssh-certs.md) — same JWT identity, different enforcement layer: a short-lived SSH cert signed from the JWT, validated by sshd's native cert auth.
