# 05 — The audit trail: who did what, when

Identity threads through every layer. This module is where that pays off — every HTTP request through Envoy lands in a structured access log with the verified user identity and the authorization decision already attached. No application instrumentation needed; no parsing IPs out of network logs and trying to figure out who they belonged to. Just `kubectl logs` and you can answer "what did alice do today?" or "did anyone get denied trying to read /bob?" in one query.

[← back to index](README.md) · prev: [04b-postgres-direct-psql.md](04b-postgres-direct-psql.md) · next: [06-grafana-audit.md](06-grafana-audit.md)

## Prerequisite

[`00-setup.md`](00-setup.md) finished. Confirm Envoy is logging:

```bash
kubectl -n ams-demo logs deploy/envoy --tail=3 | head -3
```

You should see at least one JSON line ending with something like `{"path":"/health","status":200,...}`.

## Generate some traffic

Run a mixed workload so we have something interesting to look at — a couple of users, some allowed, some denied, some anonymous:

```bash
# alice and bob each hit four routes
for U in alice bob; do
  T=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
       -d "client_id=demo-client&grant_type=password&username=$U&password=password" | jq -r .access_token)
  for P in /public /alice /bob /db; do
    curl -s -o /dev/null -H "Authorization: Bearer $T" "http://localhost:8080$P"
  done
done

# A few anonymous (will be 401)
for P in /public /alice /bob; do
  curl -s -o /dev/null "http://localhost:8080$P"
done
```

That's 11 requests total: 8 authenticated (mix of 200s and 403s), 3 unauthenticated (401s).

## What an audit-log entry looks like

Pull the most recent entries:

```bash
kubectl -n ams-demo logs deploy/envoy --tail=20 | grep '^{' | jq .
```

Each line is a JSON record with these fields:

```json
{
  "timestamp": "2026-04-28T15:32:11.842Z",
  "method": "GET",
  "path": "/alice",
  "status": 200,
  "duration_ms": 4,
  "user": "alice",
  "roles": ["user"],
  "response_flags": "-"
}
```

The fields come from `k8s/config-src/envoy.yaml`'s `access_log` block. Notable:

- **`user`** — the verified `preferred_username` from the JWT, pulled directly from the `jwt_authn` filter's metadata. Not a header sent by the client; not parseable from elsewhere; the request literally cannot reach this point if Envoy didn't validate the signature.
- **`roles`** — the verified realm roles array, same provenance.
- **`status`** — `200` (allowed and served), `401` (no/invalid JWT — Envoy short-circuited before any backend), `403` (JWT valid but RBAC denied — also short-circuited).
- **`response_flags`** — Envoy's connection-level event flags (e.g. `UH` upstream unhealthy, `UF` upstream connection failure). `-` means no special event. Authorization decisions don't show up here; the `status` field is what tells you whether the request was allowed (200) or denied at JWT (401) / RBAC (403).

## Filter by user

Find every request alice made:

```bash
kubectl -n ams-demo logs deploy/envoy | grep '^{' | jq 'select(.user == "alice")'
```

Replay alice's day in one command. Same trick to audit bob:

```bash
kubectl -n ams-demo logs deploy/envoy | grep '^{' | jq 'select(.user == "bob")'
```

## Find every denied request

The cross-user attempts (alice trying to reach `/bob`, bob trying to reach `/alice`) show up as 403s — Envoy's RBAC filter denied them after the JWT validated:

```bash
kubectl -n ams-demo logs deploy/envoy | grep '^{' | jq 'select(.status == 403)'
```

In a real environment this is the security-monitoring query — repeated 403s from a single user mean either a permission bug or someone fishing for routes they shouldn't have.

Anonymous attempts (no JWT) show up as 401s with `user: null`:

```bash
kubectl -n ams-demo logs deploy/envoy | grep '^{' | jq 'select(.status == 401)'
```

## Count requests per user

```bash
kubectl -n ams-demo logs deploy/envoy | grep '^{' | jq -r '.user // "anon"' | sort | uniq -c
```

Quick view of "who did how much" since the pod started:

```
   3 anon
   4 alice
   4 bob
```

## Live-tail the audit trail

In one terminal, tail the log with jq:

```bash
kubectl -n ams-demo logs deploy/envoy -f --since=1s \
  | grep --line-buffered '^{' \
  | jq --unbuffered .
```

In a second terminal, hit some endpoints:

```bash
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/alice >/dev/null
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/bob   >/dev/null  # 403
```

Each request appears in the first terminal within milliseconds, with the verified identity and the decision. This is what "identity-aware observability" actually feels like.

## What the other backends contribute

Envoy is the richest audit channel here, but not the only one. Each backend layer keeps its own log:

- **db-app & ssh-ca** — `kubectl logs deploy/db-app` and `kubectl logs deploy/ssh-ca` emit one line per request with the JWT identity attached:
  ```
  [2026-04-28T05:53:20.222Z] user=alice GET /
  [2026-04-28T05:53:20.268Z] user=alice POST /sign
  ```
  Same alice as in the Envoy log; same alice as in the SSH cert that comes out the other side. Identity threads through.

- **Postgres** — runs with `log_statement=all` + `pgaudit.log=read,write,role,ddl`, so `kubectl logs deploy/postgres` shows the SQL-layer audit trail:
  ```
  dbproxy@demo LOG:  statement: SET LOCAL ROLE "alice"
  dbproxy@demo LOG:  statement: SELECT id, owner, title, body FROM documents ORDER BY id
  dbproxy@demo LOG:  AUDIT: SESSION,12,1,READ,SELECT,,,"SELECT id, owner, title, body FROM documents ORDER BY id",<not logged>
  ```
  The login user (`dbproxy`) is always the same — that's the connection auth — but the `SET LOCAL ROLE "alice"` line *is* the identity assertion. pgaudit's `AUDIT: SESSION,...,READ,SELECT,...` lines classify by statement type so you can filter for "all writes" or "all role-altering statements" specifically.

- **sshd** — `kubectl logs deploy/sshd` shows the standard OpenSSH auth log: cert ID, principal, signing CA fingerprint, source IP. Every successful login looks like `Accepted publickey for alice from 10.244.x.x: ED25519-CERT SHA256:... ID alice-1714323456-... CA ED25519 SHA256:...`. The Key ID is your link back to which Keycloak token signed it.

- **Grafana** — `kubectl logs deploy/grafana` shows operational logs with `uname=alice` on every action — login, dashboard access, datasource queries.

Same identity (`alice`, `bob`), five logs, five different perspectives. Stitching them together in a real SIEM is the production-y next step — but for this workshop the point is that each layer *has* the identity to log, because each layer enforced something with it.

## Why this matters

Three things that make this kind of audit fundamentally different from the network-level logs you might have grown up with:

1. **Identity is the primary key, not IP.** Network logs say "10.0.4.7 hit /alice." That's useless without a NAT table, a DHCP lease record, and a guess about whether 10.0.4.7 was alice or bob at that moment. The Envoy log says `"user": "alice"` because Keycloak signed off on it before the request reached this code path.
2. **Authorization decisions are first-class.** A 403 in the Envoy log isn't just "request failed" — it's "request *was identified*, *then* denied." Pattern of repeated 403s from one identity is a different signal than 5xx from one IP.
3. **Backends inherit the identity for free.** Once Envoy validates the JWT, every backend in the chain (db-app's own logs, sshd's auth.log, etc.) gets to record under the same identity. No coordinated logging spec across teams; no out-of-band identity correlation. The identity *is* the request.

For compliance frameworks that ask "who accessed PII X on date Y" — that's a single `jq 'select(.user == "X")'` over a date-bounded log slice, not a multi-system correlation project.

---

→ Next: [**06-grafana-audit.md**](06-grafana-audit.md) — same audit log, but in Grafana via Loki, with filters and live updates.
