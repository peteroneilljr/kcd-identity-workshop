#!/usr/bin/env bash
# Full integration test suite for the ams-demo Kubernetes deployment.
# Asserts the complete identity → backend matrix: HTTP authz, Postgres RLS,
# Grafana OIDC, and SSH cert flow. Manages its own port-forwards so it can
# be run from a clean shell after `kubectl apply -f k8s/`.

set -u

NS=ams-demo
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { echo "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label (got $actual)"
  else fail "$label (expected $expected, got $actual)"; fi
}

# ---------- preflight ----------
for tool in kubectl curl jq python3 ssh ssh-keygen nc psql openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "${RED}missing required tool: $tool${NC}"; exit 2; }
done

if ! kubectl -n "$NS" get deploy >/dev/null 2>&1; then
  echo "${RED}namespace $NS not found — run: kubectl apply -f k8s/${NC}"
  exit 2
fi

echo "${BLUE}Waiting for all deployments in $NS to be Available...${NC}"
kubectl -n "$NS" wait --for=condition=Available --timeout=120s deploy --all >/dev/null \
  || { echo "${RED}some deployment isn't Available${NC}"; kubectl -n "$NS" get pods; exit 2; }

# ---------- port-forwards (managed by this script) ----------
PF_PIDS=()
WORK=$(mktemp -d)
start_pf() {
  local svc="$1" local_port="$2" remote_port="$3"
  kubectl -n "$NS" port-forward "svc/$svc" "$local_port:$remote_port" >/dev/null 2>&1 &
  local pid=$!
  PF_PIDS+=("$pid")
  # disown so bash doesn't print "Terminated" job-control noise on cleanup.
  disown "$pid" 2>/dev/null || true
}
cleanup() {
  for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

start_pf keycloak 8180 8180
start_pf envoy    8080 8080
start_pf grafana  3300 3000
start_pf sshd     2222 22
start_pf postgres 5432 5432

# Wait for forwards to come up. nc is more deterministic than sleep.
echo "${BLUE}Waiting for port-forwards...${NC}"
for port in 8180 8080 3300 2222 5432; do
  for i in $(seq 1 30); do
    nc -z -w1 localhost "$port" >/dev/null 2>&1 && break
    sleep 0.5
    if [ "$i" -eq 30 ]; then echo "${RED}timeout waiting for localhost:$port${NC}"; exit 2; fi
  done
done
echo

# ---------- helpers ----------
get_token() {
  curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
    -d "client_id=demo-client&grant_type=password&username=$1&password=password" \
    | jq -r '.access_token'
}

http_status() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

TOKEN_ALICE=$(get_token alice)
TOKEN_BOB=$(get_token bob)
[ -n "$TOKEN_ALICE" ] && [ "$TOKEN_ALICE" != "null" ] && pass "obtained alice token" || { fail "alice token"; exit 1; }
[ -n "$TOKEN_BOB"   ] && [ "$TOKEN_BOB"   != "null" ] && pass "obtained bob token"   || { fail "bob token";   exit 1; }

# ---------- Suite 1: HTTP authz ----------
echo
echo "${YELLOW}[Suite 1: HTTP authz — Envoy JWT + RBAC]${NC}"

assert_eq "anon  /public" 401 "$(http_status http://localhost:8080/public)"
assert_eq "anon  /alice"  401 "$(http_status http://localhost:8080/alice)"
assert_eq "anon  /bob"    401 "$(http_status http://localhost:8080/bob)"
assert_eq "anon  /health" 200 "$(http_status http://localhost:8080/health)"

assert_eq "alice /public" 200 "$(http_status -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/public)"
assert_eq "alice /alice"  200 "$(http_status -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/alice)"
assert_eq "alice /bob"    403 "$(http_status -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/bob)"

assert_eq "bob   /public" 200 "$(http_status -H "Authorization: Bearer $TOKEN_BOB"   http://localhost:8080/public)"
assert_eq "bob   /alice"  403 "$(http_status -H "Authorization: Bearer $TOKEN_BOB"   http://localhost:8080/alice)"
assert_eq "bob   /bob"    200 "$(http_status -H "Authorization: Bearer $TOKEN_BOB"   http://localhost:8080/bob)"

# ---------- Suite 2: Postgres RLS ----------
echo
echo "${YELLOW}[Suite 2: Postgres RLS — db-app + SET ROLE]${NC}"

db_owners() {
  curl -s -H "Authorization: Bearer $1" http://localhost:8080/db \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(",".join(sorted(set(r["owner"] for r in d["visible_documents"]))))'
}
assert_eq "alice sees only {alice,public}" "alice,public" "$(db_owners "$TOKEN_ALICE")"
assert_eq "bob   sees only {bob,public}"   "bob,public"   "$(db_owners "$TOKEN_BOB")"
assert_eq "anon  /db blocked at gateway"   401            "$(http_status http://localhost:8080/db)"

# ---------- Suite 3: Grafana OIDC ----------
echo
echo "${YELLOW}[Suite 3: Grafana OIDC — full code flow]${NC}"

oauth_login_role() {
  local user="$1" jar html
  jar=$(mktemp); html=$(mktemp)
  # 1) Init OAuth: Grafana sets state cookie, redirects to Keycloak login form.
  curl -sS -L -c "$jar" -b "$jar" -o "$html" \
    -A "matrix-runner" \
    "http://localhost:3300/login/generic_oauth" >/dev/null 2>&1
  # 2) Find the form action URL.
  local action
  action=$(python3 -c '
import sys, re, html as H
s = open(sys.argv[1]).read()
m = re.search(r"<form[^>]+id=\"kc-form-login\"[^>]+action=\"([^\"]+)\"", s) \
    or re.search(r"action=\"([^\"]+)\"[^>]+id=\"kc-form-login\"", s)
print(H.unescape(m.group(1)) if m else "")
' "$html")
  [ -z "$action" ] && { rm -f "$jar" "$html"; echo ""; return; }
  # 3) POST credentials, follow redirect chain back through Keycloak -> Grafana callback.
  curl -sS -L -c "$jar" -b "$jar" -o /dev/null -A "matrix-runner" \
    -d "username=${user}&password=password&credentialId=" "$action"
  # 4) Read user's org role from Grafana.
  curl -sS -b "$jar" "http://localhost:3300/api/user/orgs" \
    | python3 -c 'import sys,json; o=json.load(sys.stdin); print(o[0]["role"] if o else "")' 2>/dev/null
  rm -f "$jar" "$html"
}
assert_eq "alice -> Grafana Viewer" "Viewer" "$(oauth_login_role alice)"
assert_eq "bob   -> Grafana Admin"  "Admin"  "$(oauth_login_role bob)"

# ---------- Suite 4: SSH cert flow ----------
echo
echo "${YELLOW}[Suite 4: SSH cert flow — ssh-ca + sshd]${NC}"

ssh-keygen -t ed25519 -f "$WORK/alice_id" -N "" -q -C "alice@matrix"
ssh-keygen -t ed25519 -f "$WORK/bob_id"   -N "" -q -C "bob@matrix"

sign() {
  curl -sf -X POST -H "Authorization: Bearer $1" -H "Content-Type: text/plain" \
    --data-binary @"$2" http://localhost:8080/ssh-ca/sign > "$3"
}
sign "$TOKEN_ALICE" "$WORK/alice_id.pub" "$WORK/alice_id-cert.pub"
sign "$TOKEN_BOB"   "$WORK/bob_id.pub"   "$WORK/bob_id-cert.pub"
[ -s "$WORK/alice_id-cert.pub" ] && pass "alice cert signed"   || fail "alice cert empty"
[ -s "$WORK/bob_id-cert.pub"   ] && pass "bob   cert signed"   || fail "bob cert empty"

ssh_cmd() {
  ssh -i "$1" -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o BatchMode=yes \
      -p 2222 "$2"@localhost "$3" 2>&1
}
ssh_login_ok() {
  local out; out=$(ssh_cmd "$1" "$2" whoami)
  if [ "$out" = "$2" ]; then pass "$3"; else fail "$3 (got: $out)"; fi
}
ssh_login_denied() {
  local out; out=$(ssh_cmd "$1" "$2" whoami)
  if echo "$out" | grep -q "Permission denied"; then pass "$3"
  else fail "$3 (got: $out)"; fi
}

ssh_login_ok      "$WORK/alice_id" alice "alice cert -> ssh alice@host"
ssh_login_denied  "$WORK/alice_id" bob   "alice cert -> ssh bob@host  (cross-user)"
ssh_login_ok      "$WORK/bob_id"   bob   "bob   cert -> ssh bob@host"
ssh_login_denied  "$WORK/bob_id"   alice "bob   cert -> ssh alice@host (cross-user)"

assert_eq "anon /ssh-ca/sign blocked" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
       -H "Content-Type: text/plain" --data-binary @"$WORK/alice_id.pub" \
       http://localhost:8080/ssh-ca/sign)"

# Naked key (no cert): sshd should refuse since AuthorizedKeysFile=none.
out=$(ssh -i "$WORK/alice_id" -o IdentitiesOnly=yes \
       -o CertificateFile=/dev/null \
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR -o BatchMode=yes \
       -p 2222 alice@localhost whoami 2>&1)
if echo "$out" | grep -q "Permission denied"; then pass "naked key (no cert) refused"
else fail "naked key (no cert) refused (got: $out)"; fi

# ---------- Suite 5: pg-ca direct psql ----------
echo
echo "${YELLOW}[Suite 5: Postgres direct psql — pg-ca cert + RLS]${NC}"

# Pull the CA cert for sslrootcert.
kubectl -n "$NS" get cm pg-ca-cert -o jsonpath='{.data.ca\.crt}' > "$WORK/pg-ca.crt"
[ -s "$WORK/pg-ca.crt" ] && pass "fetched pg-ca CA cert" || fail "pg-ca CA cert empty"

# Generate per-user keypairs + CSRs, sign via /pg-ca/sign with each JWT.
pg_sign() {
  local user="$1" token="$2"
  openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$WORK/${user}_db.key" -out "$WORK/${user}_db.csr" \
    -subj "/CN=${user}" 2>/dev/null
  chmod 600 "$WORK/${user}_db.key"
  curl -sf -X POST -H "Authorization: Bearer $token" \
    -H "Content-Type: text/plain" --data-binary @"$WORK/${user}_db.csr" \
    http://localhost:8080/pg-ca/sign \
    > "$WORK/${user}_db.crt"
}
pg_sign alice "$TOKEN_ALICE"
pg_sign bob   "$TOKEN_BOB"
[ -s "$WORK/alice_db.crt" ] && pass "alice cert signed by pg-ca" || fail "alice pg cert empty"
[ -s "$WORK/bob_db.crt"   ] && pass "bob   cert signed by pg-ca" || fail "bob pg cert empty"

# kubectl port-forward into a TLS-enabled Postgres can drop after a single
# connection on Docker Desktop. Refresh the forward before each psql call so
# the suite is robust to that.
restart_pg_pf() {
  pkill -f "port-forward.*postgres" 2>/dev/null
  sleep 1
  kubectl -n "$NS" port-forward svc/postgres 5432:5432 >/dev/null 2>&1 &
  PF_PIDS+=("$!"); disown "$!" 2>/dev/null || true
  for i in $(seq 1 20); do
    nc -z -w1 localhost 5432 >/dev/null 2>&1 && return 0
    sleep 0.3
  done
  return 1
}

# psql owners as a given (cert,user) — empty string on connection failure.
pg_owners() {
  local cert="$1" key="$2" user="$3"
  restart_pg_pf
  PGSSLCERT="$cert" PGSSLKEY="$key" PGSSLROOTCERT="$WORK/pg-ca.crt" \
    psql "host=localhost port=5432 dbname=demo user=$user sslmode=verify-ca" \
      -tAc "SELECT string_agg(DISTINCT owner, ',' ORDER BY owner) FROM documents" 2>/dev/null
}
assert_eq "alice cert -> psql alice: sees {alice,public}" "alice,public" \
  "$(pg_owners "$WORK/alice_db.crt" "$WORK/alice_db.key" alice)"
assert_eq "bob   cert -> psql bob:   sees {bob,public}"   "bob,public"   \
  "$(pg_owners "$WORK/bob_db.crt"   "$WORK/bob_db.key"   bob)"

# Cross-user attempt: alice's cert connecting as user=bob must fail.
restart_pg_pf
out=$(PGSSLCERT="$WORK/alice_db.crt" PGSSLKEY="$WORK/alice_db.key" PGSSLROOTCERT="$WORK/pg-ca.crt" \
      psql "host=localhost port=5432 dbname=demo user=bob sslmode=verify-ca" -tAc "SELECT 1" 2>&1)
if echo "$out" | grep -q "certificate authentication failed"; then
  pass "alice cert -> psql bob (cross-user) rejected"
else
  fail "alice cert -> psql bob expected cert auth fail (got: $out)"
fi

# Cert must include extKeyUsage:clientAuth and CN matching the JWT user even
# when the CSR claims a different CN (server-side substitution).
openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -keyout "$WORK/sneaky.key" -out "$WORK/sneaky.csr" \
  -subj "/CN=bob" 2>/dev/null
chmod 600 "$WORK/sneaky.key"
curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: text/plain" --data-binary @"$WORK/sneaky.csr" \
  http://localhost:8080/pg-ca/sign > "$WORK/sneaky.crt"
sneaky_cn=$(openssl x509 -in "$WORK/sneaky.crt" -noout -subject 2>/dev/null \
            | sed -E 's/.*CN ?= ?([^,]+).*/\1/' | tr -d ' ')
assert_eq "pg-ca rewrites CSR CN -> JWT user" "alice" "$sneaky_cn"

# anon /pg-ca/sign blocked at gateway.
assert_eq "anon /pg-ca/sign blocked" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST \
       -H "Content-Type: text/plain" --data-binary @"$WORK/alice_db.csr" \
       http://localhost:8080/pg-ca/sign)"

# ---------- summary ----------
echo
echo "=========================================="
if [ $FAIL -eq 0 ]; then
  echo "${GREEN}  ALL $PASS ASSERTIONS PASSED${NC}"
else
  echo "${RED}  $FAIL FAILED, $PASS PASSED${NC}"
  for n in "${FAILED_NAMES[@]}"; do echo "    - $n"; done
fi
echo "=========================================="
[ $FAIL -eq 0 ]
