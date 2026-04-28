# 03 — Postgres: SET ROLE + RLS keyed on Keycloak identity

So far you've used a Keycloak identity in two systems that *understood* it natively — Grafana via OIDC, Envoy via JWT bearer auth. This module is the first **bridge**: a system that can't speak JWT at all.

Postgres can't validate JWTs. So `db-app` does the bridge: it reads the JWT identity Envoy forwards (as `x-jwt-payload`), runs `SET LOCAL ROLE "<username>"` inside a transaction, and queries. Postgres' row-level security filters per `current_user`. The DB itself enforces who-sees-what — even a buggy `db-app` couldn't leak rows. This pattern (HTTP gateway validates JWT → small bridge service translates to a protocol-native credential → resource enforces with its own auth model) generalizes to a lot of non-JWT systems.

[← back to index](README.md) · prev: [02-http-authz.md](02-http-authz.md) · next: [04-ssh-certs.md](04-ssh-certs.md)

## Prerequisite

[`00-setup.md`](00-setup.md) finished. Tokens may have expired since the previous module — re-fetch:

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r .access_token)
```

## alice queries the DB

`/db` is reachable by any authenticated user — RLS handles per-user filtering at the DB layer, not the gateway.

```bash
curl -s -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/db \
  | jq '.visible_documents'
```

Expect alice's two rows + the shared `public` row, **never** bob's:

```json
[
  { "id": 1, "owner": "alice",  "title": "Alice notes",         "body": "..." },
  { "id": 2, "owner": "alice",  "title": "Alice TODO",          "body": "..." },
  { "id": 5, "owner": "public", "title": "Shared announcement", "body": "..." }
]
```

## bob queries the same endpoint, sees a different result

```bash
curl -s -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/db \
  | jq '.visible_documents'
```

Mirror image — bob sees only `{bob, public}`.

The endpoint, the SQL query, and the request path are **identical** for both users. The difference is which JWT identity arrived at db-app. Postgres' RLS does the rest.

## How it works (one paragraph)

`db-app` reads `x-jwt-payload` from Envoy, decodes `preferred_username`, opens a tx, runs `SET LOCAL ROLE "<username>"`, then `SELECT * FROM documents`. The `documents` table has this RLS policy:

```sql
CREATE POLICY documents_owner_or_public ON documents
  FOR SELECT
  USING (owner = current_user OR owner = 'public');
```

`current_user` reflects whichever role we just `SET ROLE`d into. `SET LOCAL` is reset at end-of-tx, so role can't leak across pooled connections. The login user is `dbproxy` (`NOINHERIT` — has no privileges of its own), and it has `GRANT alice TO dbproxy` and `GRANT bob TO dbproxy` so it can switch into either.

## Optional: interactive psql

Want to poke at the same DB directly? Run an extra port-forward and connect as `dbproxy`:

```bash
kubectl -n ams-demo port-forward svc/postgres 5432:5432 &
PGPASSWORD=dbproxy psql -h localhost -U dbproxy demo
```

Then inside psql:

```sql
SET ROLE alice;
SELECT * FROM documents;     -- alice's view: alice rows + public

RESET ROLE;
SET ROLE bob;
SELECT * FROM documents;     -- bob's view: bob rows + public

RESET ROLE;
SELECT * FROM documents;     -- dbproxy with no role: 0 rows, RLS blocks all
```

That last query confirms `dbproxy` has no privileges of its own — it's a pure switcher role.

## Why this matters

The trust boundary is the **database**, not the application. If db-app had a bug — say it forgot to call `SET ROLE`, or got tricked into using a different identity — the worst it could do is run as `dbproxy` (which has no privileges). It cannot impersonate alice as bob, because the DB role is what's checked at row-level, and Envoy already validated which JWT was presented.

This is the same architectural pattern as Envoy's RBAC, just at a different layer: the system that's authoritative for the data (Postgres) is also authoritative for who-can-see-what.

---

→ Next: [**04-ssh-certs.md**](04-ssh-certs.md) — same JWT, this time bridged into SSH cert auth (a non-HTTP protocol).
