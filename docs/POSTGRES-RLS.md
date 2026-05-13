# Postgres Row-Level Security with Keycloak Identities

This document explains how the demo bridges a Keycloak JWT identity into Postgres without Postgres ever needing to understand JWTs. The trust boundary is the **database**, not the application — even a buggy or compromised `db-app` cannot leak rows across users.

![Envoy forwards `x-jwt-payload` to db-app; db-app decodes it, validates the allowlist, connects as the NOINHERIT login role `dbproxy`, and issues `SET LOCAL ROLE alice`; Postgres RLS policy on `documents` filters rows by `current_user`](../assets/POSTGRES-RLS.svg)

## Table of Contents

1. [The problem: Postgres doesn't speak OIDC](#the-problem-postgres-doesnt-speak-oidc)
2. [The solution at a glance](#the-solution-at-a-glance)
3. [Roles and role membership](#roles-and-role-membership)
4. [`NOINHERIT` and why the proxy role has no privileges](#noinherit-and-why-the-proxy-role-has-no-privileges)
5. [`SET ROLE` vs `SET LOCAL ROLE`](#set-role-vs-set-local-role)
6. [Row-Level Security policies](#row-level-security-policies)
7. [`current_user` is the linchpin](#current_user-is-the-linchpin)
8. [End-to-end request flow](#end-to-end-request-flow)
9. [What this design protects against](#what-this-design-protects-against)
10. [Production considerations](#production-considerations)

---

## The problem: Postgres doesn't speak OIDC

Keycloak issues JWTs. Envoy validates them. The HTTP services in this demo can read the verified `x-jwt-payload` header forwarded by Envoy and *trust* whatever's in there because Envoy already verified the signature.

Postgres has no such filter. Its native authentication is one of:

- Password (`md5`, `scram-sha-256`)
- Client TLS cert
- LDAP / Kerberos / GSSAPI
- Trust (skip auth entirely — local connections only)
- IDENT / peer (uses the OS-level user)

There's no built-in "validate this JWT and become that user" mode. Even if you patched it in, you'd still have to map JWT claims to Postgres roles, and you'd still want row-level filtering — so the question becomes: how do you make Postgres' *own* authorization model honor the upstream identity?

## The solution at a glance

```
Keycloak JWT (preferred_username = "alice")
        │
        ▼
Envoy   ── validates signature, decodes claims
        ── forwards x-jwt-payload header
        │
        ▼
db-app  ── reads x-jwt-payload, extracts preferred_username
        ── opens transaction
        ── SET LOCAL ROLE "alice"     ← THE BRIDGE
        ── SELECT * FROM documents
        ── COMMIT
        │
        ▼
Postgres
        ── current_user is now "alice"
        ── RLS policy: USING (owner = current_user OR owner = 'public')
        ── filters rows by current_user
        ── returns only alice's + public rows
```

Three pieces working together:

1. **Roles** named after each Keycloak user (`alice`, `bob`).
2. **A login role** (`dbproxy`) that holds membership in those user roles but has no inherent privileges.
3. **Row-Level Security** on the `documents` table, keyed on `current_user`.

`db-app` is just glue — it converts an HTTP-layer identity claim into a SQL-layer role assumption. The DB itself does the actual filtering.

## Roles and role membership

Postgres roles are dual-purpose: they can be users (login enabled, password set, can connect) or groups (no login, but other roles can be members).

This demo creates three roles:

```sql
-- The two "user" roles. NOLOGIN: you can't connect as alice or bob directly.
CREATE ROLE alice NOLOGIN;
CREATE ROLE bob   NOLOGIN;

-- The login role db-app uses to connect. NOINHERIT: holding membership
-- doesn't automatically grant you the member's privileges.
CREATE ROLE dbproxy WITH LOGIN PASSWORD 'dbproxy' NOINHERIT;

-- dbproxy is a member of both user roles, so it can SET ROLE to either.
GRANT alice TO dbproxy;
GRANT bob   TO dbproxy;
```

After this:

- Connecting as `alice` directly: refused. `NOLOGIN` blocks it.
- Connecting as `dbproxy`: works. `dbproxy` is the only login role.
- `dbproxy` can `SET ROLE alice` or `SET ROLE bob` because it's a member.

Membership doesn't transfer privileges automatically because of the next part.

## `NOINHERIT` and why the proxy role has no privileges

By default in Postgres, role membership is **inherited**: if `dbproxy` is a member of `alice`, `dbproxy` automatically holds all of `alice`'s privileges, even without `SET ROLE`. That's the wrong default for our purposes — it would mean `dbproxy` always sees everyone's data, and an attacker who got the `dbproxy` connection would see every row in the database.

`NOINHERIT` flips this:

```sql
CREATE ROLE dbproxy WITH LOGIN PASSWORD 'dbproxy' NOINHERIT;
```

Now membership is **explicit**:

- `dbproxy` is a member of `alice`, but holds no `alice` privileges by default.
- To act as alice, `dbproxy` must explicitly run `SET ROLE alice`.
- After `SET ROLE alice`, it loses its connection-level privileges (which were nothing anyway) and operates exactly as alice.
- After `RESET ROLE` (or end-of-tx for `SET LOCAL`), it goes back to having no privileges.

```sql
-- As dbproxy, no role assumed:
SELECT * FROM documents;       -- 0 rows (RLS blocks all — no role matches)
SELECT current_user;           -- "dbproxy"

SET ROLE alice;
SELECT current_user;           -- "alice"
SELECT * FROM documents;       -- alice's rows + public rows

RESET ROLE;
SELECT current_user;           -- "dbproxy" again, 0 rows visible
```

The principle is **least privilege at the connection level**. A leaked connection gives the attacker `dbproxy`'s authority — which is *zero* until they explicitly assume a role. And in the demo, `db-app` only ever assumes a role for users that just authenticated to Keycloak via Envoy.

## `SET ROLE` vs `SET LOCAL ROLE`

Two flavors of `SET ROLE` exist, and the choice matters for connection pooling.

| Form | Scope | Reset on |
|---|---|---|
| `SET ROLE alice` | Session | `RESET ROLE`, end of session, or another `SET ROLE` |
| `SET LOCAL ROLE alice` | Current transaction only | `COMMIT`, `ROLLBACK`, or `RESET ROLE` |

Why this matters: `db-app` uses a connection pool. Connections are reused across requests. If request 1 from alice runs `SET ROLE alice`, returns the connection to the pool, and request 2 from bob picks up that same connection without resetting, bob's query would run as alice.

`SET LOCAL ROLE` solves this — it's automatically cleared when the transaction ends:

```js
const client = await pool.connect();
try {
  await client.query('BEGIN');
  await client.query(`SET LOCAL ROLE "${user}"`);   // alice or bob
  const r = await client.query('SELECT * FROM documents');
  await client.query('COMMIT');
  return r.rows;
} finally {
  client.release();   // returns to pool with role reset (because LOCAL)
}
```

When `client.release()` returns the connection to the pool, the role assumption is gone. The next checkout starts as `dbproxy` again.

`SET ROLE` (without `LOCAL`) would require explicit `RESET ROLE` before release, and a forgotten reset would silently leak privileges. `SET LOCAL ROLE` is the safer default.

## Row-Level Security policies

RLS is the mechanism that actually filters rows based on the assumed role. Three things make a table RLS-protected:

```sql
-- 1. Enable RLS on the table.
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- 2. Force RLS even for the table owner. Without this, the role that owns
--    the table (or any superuser) bypasses all RLS policies.
ALTER TABLE documents FORCE ROW LEVEL SECURITY;

-- 3. Define one or more policies.
CREATE POLICY documents_owner_or_public ON documents
  FOR SELECT
  USING (owner = current_user OR owner = 'public');
```

The `USING` clause is a per-row predicate evaluated as part of every `SELECT`. Postgres effectively rewrites:

```sql
SELECT * FROM documents;
```

…to:

```sql
SELECT * FROM documents WHERE (owner = current_user OR owner = 'public');
```

Rows that don't match the predicate are silently filtered out — they don't appear, and the query doesn't even reveal that they exist.

For other operations (`INSERT`, `UPDATE`, `DELETE`), you'd write separate policies with `FOR INSERT`, `FOR UPDATE`, etc., each with `USING` (existing-row predicate) and/or `WITH CHECK` (new-row predicate). The demo only does `SELECT`, so we have one policy.

### The grant pattern

For RLS to even be considered, the role has to have base table privileges. The demo grants:

```sql
GRANT SELECT ON documents          TO alice, bob;
GRANT USAGE, SELECT ON SEQUENCE documents_id_seq TO alice, bob;
```

So:

- `dbproxy` (no SELECT grant on documents) → can't read anything regardless of RLS, because lack of base privilege is checked first.
- `alice` (has SELECT) → can read, RLS filters to her rows + public.
- `bob` (has SELECT) → can read, RLS filters to his rows + public.

## `current_user` is the linchpin

`current_user` is a Postgres-builtin that returns the *currently active* role — not the session role, not the connection user, but whatever role is in effect for SQL execution right now. After `SET LOCAL ROLE alice`, `current_user` is `'alice'`.

The RLS policy is parameterized on `current_user`, so the same query produces different results depending on who the role is:

```sql
-- Run by db-app for alice (after SET LOCAL ROLE alice):
SELECT id, owner FROM documents;
-- 1 | alice
-- 2 | alice
-- 5 | public
-- (rows 3,4 owned by bob: filtered out)

-- Run by db-app for bob (after SET LOCAL ROLE bob):
SELECT id, owner FROM documents;
-- 3 | bob
-- 4 | bob
-- 5 | public
-- (rows 1,2 owned by alice: filtered out)
```

There's no `WHERE` clause in the application code, no role-aware logic in `db-app`, no string interpolation that could be exploited. The DB itself adds the filter. If a developer later writes `SELECT * FROM documents WHERE id = $1`, RLS still applies — they don't have to remember to add a tenant predicate.

## End-to-end request flow

What happens when alice's browser hits `/db`:

```
1. Browser              GET http://localhost:8080/db
                        Authorization: Bearer eyJhbGc...
                          │
                          ▼
2. Envoy: jwt_authn     Verify signature against Keycloak JWKS.
                        Decode payload to metadata.
                        Forward upstream as x-jwt-payload header (base64).
                          │
                          ▼
3. Envoy: rbac          Path /db, principals: [any: true].
                        Authenticated → ALLOW.
                          │
                          ▼
4. Envoy router         Forward to db_app_cluster (db-app:3003 in-cluster).
                          │
                          ▼
5. db-app              Decode x-jwt-payload base64 → JSON.
                       Read preferred_username = "alice".
                       Validate against allowlist {alice, bob}.
                       pool.connect() → checkout connection
                          │
                          ▼
6. Postgres            Connection authenticated as dbproxy.
                       BEGIN
                       SET LOCAL ROLE "alice"      → current_user = 'alice'
                       SELECT * FROM documents
                          → RLS rewrites to:
                             SELECT * FROM documents
                              WHERE owner = 'alice' OR owner = 'public'
                          → returns rows {1, 2, 5}
                       COMMIT  → SET LOCAL is reset
                          │
                          ▼
7. db-app              Format response, release connection back to pool.
                          │
                          ▼
8. Response             {"authenticated_user":"alice","db_role":"alice",
                         "visible_documents":[{id:1,...},{id:2,...},{id:5,...}]}
```

Six handoff points (browser → Envoy → Envoy filter chain → db-app → Postgres → and back). At every layer, identity is verified or assumed, but the final filtering decision is made by Postgres on the row level — the layer that *owns* the data.

## What this design protects against

### Cross-user reads (alice tries to read bob's rows)

Impossible at the SQL layer. `current_user` is `'alice'`, and the RLS predicate `owner = current_user` is false for any of bob's rows. There's no SQL alice can write that bypasses this — the predicate is added by the planner, not the application.

### Compromised db-app process

Worst case: attacker controls db-app and decides not to call `SET LOCAL ROLE` at all. Then `current_user` remains `dbproxy`, which has no `SELECT` grant on `documents`. The query fails with `permission denied for table documents`. The attacker can't even read their own data without explicitly assuming a role.

### Role confusion (db-app accidentally sets the wrong role)

If db-app had a bug that always called `SET LOCAL ROLE alice` regardless of who's asking, then bob's request would see alice's data. *That's a real risk* — you trust db-app to map JWT → SQL role correctly. Mitigations:

- The mapping is the smallest, most-reviewed piece of code (4 lines).
- Envoy already validated the JWT, so db-app doesn't need to validate identity itself — only forward it.
- The whitelist (`ALLOWED = new Set(['alice', 'bob'])`) prevents arbitrary role names from being injected.
- The `${user}` interpolation is into a quoted identifier (`"${user}"`); validated against the whitelist before it reaches SQL.

### SQL injection via JWT claim

Could an attacker craft a JWT with `preferred_username = 'alice"; DROP TABLE documents; --'`? Two layers protect against this:

1. Keycloak controls what's in the JWT. It only emits real usernames.
2. db-app validates `preferred_username` against the literal allowlist `['alice', 'bob']` before it ever reaches SQL. Anything else returns 403.

If you removed the allowlist (e.g., to support arbitrary users), you'd need stricter input validation — escaping or parameterization. Postgres has no `$1`-style parameter binding for `SET ROLE`, so you'd want a strict regex (`^[a-z][a-z0-9_]*$` etc.) or pre-existence check (`SELECT 1 FROM pg_roles WHERE rolname = $1`).

### Privilege escalation via `SET ROLE`

Postgres allows `SET ROLE` to any role you're a member of (per `pg_auth_members`). `dbproxy` is a member of `alice` and `bob`, so it can `SET ROLE alice` or `SET ROLE bob`. It is **not** a member of `postgres` (the bootstrap superuser), so `SET ROLE postgres` fails. Adding a new tenant means adding a new role and granting it to `dbproxy` — explicit, auditable.

## Production considerations

### One role per tenant doesn't always scale

This demo has 2 users. A real app might have 100,000. Creating 100,000 Postgres roles is feasible but unusual. Alternatives:

- **Session variables**: `SET LOCAL app.current_user = 'alice'` then `USING (owner = current_setting('app.current_user'))`. No role explosion. Tradeoff: weaker isolation — an attacker with SQL injection inside the tx can change `app.current_user`.
- **Hash-based partitioning**: One role per tenant *group* (e.g., shard), rows scoped by `tenant_id` column with RLS predicate `tenant_id = current_setting('app.tenant_id')::uuid`. Common for SaaS multi-tenancy.
- **Per-tenant schemas**: Isolate by schema rather than rows. Heavier, but cleanly avoids cross-tenant queries entirely.

### Connection pool warmup

`SET LOCAL ROLE` only resets at end-of-tx, but a *broken* tx (uncaught exception, network drop) might not commit/rollback cleanly. Most pool libraries handle this — they discard the connection on error. Verify your library's behavior; pgbouncer in `transaction` mode is safe by design.

### Logging and audit

Postgres' built-in `log_connections` and `pg_stat_activity` show the *connection* user (`dbproxy`), not the assumed role. To audit which Keycloak user did what, log at the application layer (db-app emits a structured log per query) or use a session-set context variable that you join with logs.

### TLS

Production Postgres should require TLS on all client connections (`hostssl` in `pg_hba.conf` and `ssl = on` in `postgresql.conf`). This demo doesn't do that — the connection is in-cluster between db-app and postgres, both ClusterIP, but in production you'd want at least mTLS or a tunnel.

### Bypassing RLS

A few ways to legitimately bypass RLS for admin tasks:

- Connect as a role with `BYPASSRLS` attribute (e.g., for backups). This demo doesn't grant that to anyone.
- The table owner can opt out unless `FORCE ROW LEVEL SECURITY` is set (which it is here).
- Superuser bypasses everything. The bootstrap `postgres` user is superuser; nothing connects as it after init.

---

## Further reading

- [Postgres docs: Row Security Policies](https://www.postgresql.org/docs/16/ddl-rowsecurity.html)
- [Postgres docs: SET ROLE](https://www.postgresql.org/docs/16/sql-set-role.html)
- [Postgres docs: Role Membership](https://www.postgresql.org/docs/16/role-membership.html)
- [Postgres docs: GRANT](https://www.postgresql.org/docs/16/sql-grant.html)
- [The 'current_user' system function](https://www.postgresql.org/docs/16/functions-info.html)
- Workshop module: [`follow-along/04-postgres-rls.md`](../follow-along/04-postgres-rls.md) — hands-on commands
