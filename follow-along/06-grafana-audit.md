# 06 — Audit trail in Grafana (Loki + LogQL)

In [05](05-audit-trail.md) you saw the audit log via `kubectl logs deploy/envoy | jq` — workable, but not how anyone actually consumes audit data in production. This module wires the same log into Grafana via Loki + Promtail, so you get a real dashboard with filters, time-series of denied requests, and live updates as you make calls. Same identity story, prettier surface — and now the Grafana you authenticated to back in module 01 has something interesting to *show* you, not just an empty dashboard.

[← back to index](README.md) · prev: [05-audit-trail.md](05-audit-trail.md) · next: [98-experiments.md](98-experiments.md)

## What's running

Three new pieces deployed by `k8s/80-loki.yaml` and `k8s/81-promtail.yaml`:

- **Loki** (single-binary mode) — log aggregation backend, listening at `http://loki:3100` in-cluster.
- **Promtail** (DaemonSet) — node agent that auto-discovers pods in the `ams-demo` namespace and ships their stdout to Loki, with labels (`app`, `pod`, `container`, `namespace`).
- **Grafana provisioning** (`k8s/82-grafana-provisioning.yaml`) — Loki is wired in as a data source, and a pre-built **Identity Audit Trail** dashboard is auto-loaded.

## Prerequisite

[`00-setup.md`](00-setup.md) finished. Confirm Loki and Promtail are Ready:

```bash
kubectl -n ams-demo get pod -l 'app in (loki,promtail)'
# both should be Running
```

## Generate some traffic

Same mixed workload as the previous module — alice + bob hit a few routes; some 200s, some 403s, some 401s:

```bash
for U in alice bob; do
  T=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
       -d "client_id=demo-client&grant_type=password&username=$U&password=password" | jq -r .access_token)
  for P in /public /alice /bob /db; do
    curl -s -o /dev/null -H "Authorization: Bearer $T" "http://localhost:8080$P"
  done
done

for P in /public /alice /bob; do
  curl -s -o /dev/null "http://localhost:8080$P"
done
```

It takes ~5 seconds for Promtail to discover and ship the new lines to Loki. Don't worry if the dashboard looks empty for a moment.

## Open the dashboard

Open <http://localhost:3300/d/audit-trail/identity-audit-trail> in your browser.

If you're not already logged in, click **Sign in with Keycloak** and use `alice/password` or `bob/password`. Either user can view the dashboard.

You'll see four stat tiles at the top, a time-series in the middle, and a live log panel at the bottom:

| Tile | What it shows |
|---|---|
| **Total requests** | All authenticated + anonymous requests in the time range |
| **401 — unauthenticated** | Anonymous attempts blocked at the JWT filter |
| **403 — RBAC denied** | Cross-user attempts (alice→/bob, bob→/alice) blocked at RBAC |
| **200 — allowed** | Requests that passed both filters |

The time-series panel below is `sum by (user)` — one line per identity over time, so you can see exactly when alice made requests vs. bob.

The log panel at the bottom is a structured stream — filterable by the `User` dropdown at the top of the dashboard.

## Filter to a single user

In the **User** dropdown at the top of the dashboard, pick `alice`. The bottom log panel and the time-series both narrow to alice's traffic only. Pick `bob` — same trick, his traffic only.

This is the dashboard equivalent of `jq 'select(.user == "alice")'` from the previous module, but you can change the filter without re-running anything.

## Watch it live

Generate more traffic from a separate terminal:

```bash
TOKEN=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

# Loop a request every second:
while true; do
  curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" http://localhost:8080/alice
  curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" http://localhost:8080/bob
  sleep 1
done
```

The dashboard refreshes every 10 seconds (configurable via the refresh dropdown in the upper right). You should see the 200 and 403 stat tiles ticking up in real time, the time-series advancing, and new entries streaming into the log panel. Cancel the loop with Ctrl+C when you've seen enough.

## Use Explore for ad-hoc queries

The dashboard covers the common cases. For one-off questions, use Grafana's **Explore** view:

1. Open the menu (left sidebar) → **Explore**.
2. Select **Loki** as the data source.
3. Try these queries:

```logql
{namespace="ams-demo", app="envoy"} | json | __error__=""
```
All envoy log entries, parsed.

```logql
{namespace="ams-demo", app="envoy"} | json | __error__="" | status="403"
```
Only the RBAC denials. (`status="401"` for unauthenticated attempts.)

```logql
sum by (user) (count_over_time({namespace="ams-demo", app="envoy"} | json | __error__="" [1m]))
```
Per-user request rate over time.

```logql
{namespace="ams-demo", app=~"db-app|ssh-ca"} |~ "user="
```
The bridge services' application logs — every request is tagged with the JWT identity (`user=alice GET /` etc.), so you can correlate "alice hit /db" with the corresponding Envoy 200 and the Postgres SET ROLE that followed.

```logql
{namespace="ams-demo", app="postgres"} |~ "SET LOCAL ROLE"
```
Every role assumption inside `db-app`'s transactions, in chronological order. Pair this with the Envoy panel above to see "alice hit `/db`" → "db-app set role alice" → "Postgres ran SELECT" all in one timeline.

```logql
{namespace="ams-demo", app="postgres"} |~ "AUDIT:"
```
pgaudit's structured audit lines: `AUDIT: SESSION,12,1,READ,SELECT,...` with the statement type, class (READ/WRITE/ROLE/DDL), and the actual SQL. Filter to `WRITE` to get all mutations cluster-wide:

```logql
{namespace="ams-demo", app="postgres"} |~ "AUDIT: SESSION,.*,WRITE,"
```

## Why this matters

What changed from the previous module isn't the *substance* — it's the **interface**. The Envoy access log was always structured JSON tagged with the verified identity; we just consumed it via `kubectl logs | jq` last time and via Grafana this time.

Three reasons the Grafana view matters in production:

1. **Time-bounded queries.** *"Show me every 403 in the last 24 hours"* is one click. With raw `kubectl logs`, you'd be juggling `--since`, log rotation, and pod restarts.
2. **Multi-source correlation.** Promtail ships logs from *every* pod in `ams-demo`, not just Envoy. The same dashboard could plot `db-app` errors next to Envoy 403s, line them up by timestamp, see if a permission denial cascaded somewhere. This workshop only shows the Envoy panel, but the data is already in Loki.
3. **Persistence past pod restarts.** `kubectl logs` only shows the current pod's stdout. Restart the pod and the history is gone (well, recoverable via `--previous` exactly once). Loki keeps everything.

What it's *not*:

- It's still **logs**, not traces. You can see "alice's request was denied at 14:32:11" but not the latency breakdown across Envoy → db-app → Postgres for a single request. That's distributed tracing — same Grafana stack would extend with Tempo + OpenTelemetry, but that's a different workshop.
- It's still **gateway-level** auditing. The Postgres DB layer's audit (which row alice actually read) isn't here — it would need pgaudit + a separate log channel into Loki. The pattern is the same; the wiring is per-system.
- It's **post-hoc**, not preventive. Envoy's RBAC filter prevented the 403 from succeeding; the audit log records that it happened. They're complementary — never one or the other.

The thesis still holds: **identity is the primary key everywhere it matters**. The previous module showed this with `jq`; this one shows it with a dashboard. Same data, same trust chain, prettier presentation.

---

→ Next: [**98-experiments.md**](98-experiments.md) — bonus experiments probing the edges of the security model.
