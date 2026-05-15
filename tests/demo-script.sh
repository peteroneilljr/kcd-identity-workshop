#!/usr/bin/env bash
# Interactive walkthrough of the ams-demo Kubernetes deployment.
# Same paused/colored style as before, but covers the four backends:
# HTTP authz, Postgres RLS, Grafana OIDC, SSH cert auth.

NS=ams-demo

# $'...' (ANSI-C quoting) stores the actual ESC byte, so these render
# whether the surrounding command uses `echo`, `echo -e`, or `printf`.
# (Plain '\033...' would print literal "\033[0;31m" through bare `echo`.)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

print_header() {
    clear
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}
print_separator() { echo ""; echo -e "${BLUE}----------------------------------------${NC}"; echo ""; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${YELLOW}→ $1${NC}"; }
print_command() {
    echo ""
    echo -e "${BOLD}${MAGENTA}  \$ $1${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}▶ [Press Enter to run]${NC}"
    read -r
}
pause() { echo ""; echo -e "${MAGENTA}→ [Press Enter to continue]${NC}"; read -r; }

# ---------- preflight ----------
for tool in kubectl curl jq ssh ssh-keygen nc; do
  command -v "$tool" >/dev/null 2>&1 || { print_error "missing tool: $tool"; exit 2; }
done

print_header "[0/12] Verify cluster and namespace"
print_info "Checking $NS namespace and pod readiness..."
if ! kubectl -n "$NS" get deploy >/dev/null 2>&1; then
    print_error "namespace $NS not found. Run: kubectl apply -f k8s/"
    exit 1
fi
kubectl -n "$NS" wait --for=condition=Available --timeout=120s deploy --all >/dev/null \
  && print_success "All deployments Available" \
  || { print_error "some deployment isn't Available"; kubectl -n "$NS" get pods; exit 1; }

# ---------- port-forwards ----------
PF_PIDS=()
start_pf() {
  kubectl -n "$NS" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  local pid=$!; PF_PIDS+=("$pid"); disown "$pid" 2>/dev/null || true
}
cleanup() { for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

start_pf keycloak 8180 8180
start_pf envoy    8080 8080
start_pf grafana  3300 3000
start_pf sshd     2222 22
for port in 8180 8080 3300 2222; do
  for i in $(seq 1 30); do
    nc -z -w1 localhost "$port" >/dev/null 2>&1 && break
    sleep 0.5
  done
done
print_success "Port-forwards up: keycloak:8180  envoy:8080  grafana:3300  sshd:2222"
pause

# ============================================================
# Step 1: Unauthenticated request
# ============================================================
print_header "[1/12] Unauthenticated access (should fail)"
print_info "Without a valid JWT, Envoy blocks every request..."
print_command "curl -si http://localhost:8080/public"
HTTP_CODE=$(curl -si -o /tmp/response.txt -w "%{http_code}" http://localhost:8080/public)
cat /tmp/response.txt; echo ""
print_separator
[ "$HTTP_CODE" = "401" ] && print_success "Blocked (401 Unauthorized)" || print_error "expected 401, got $HTTP_CODE"
pause

# ============================================================
# Step 2: Authenticate as alice, decode JWT
# ============================================================
print_header "[2/12] Authenticate as alice"
print_info "Get a JWT from Keycloak via password grant..."
print_command "curl -s -X POST http://localhost:8180/realms/demo/protocol/openid-connect/token \\
  -d 'client_id=demo-client&grant_type=password&username=alice&password=password'"

TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r '.access_token')
[ -n "$TOKEN_ALICE" ] && [ "$TOKEN_ALICE" != "null" ] || { print_error "no token"; exit 1; }
print_success "Got Alice's JWT (${#TOKEN_ALICE} chars)"
pause

print_info "Decoding the payload to see what's in it..."
PAYLOAD=$(echo "$TOKEN_ALICE" | cut -d'.' -f2)
case $((${#PAYLOAD} % 4)) in 2) PAYLOAD="${PAYLOAD}==" ;; 3) PAYLOAD="${PAYLOAD}=" ;; esac
echo "$PAYLOAD" | base64 -d 2>/dev/null | jq '{username: .preferred_username, email, roles: .realm_access.roles, exp}'
pause

# ============================================================
# Step 3: alice -> /public
# ============================================================
print_header "[3/12] alice → /public (should succeed)"
print_command "curl -H 'Authorization: Bearer \$TOKEN_ALICE' http://localhost:8080/public"
HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/public)
echo "HTTP Status: $HTTP_CODE"; cat /tmp/response.txt | jq '.'
print_separator
[ "$HTTP_CODE" = "200" ] && print_success "200 — anyone authenticated can reach /public" || print_error "expected 200, got $HTTP_CODE"
pause

# ============================================================
# Step 4: alice -> /alice
# ============================================================
print_header "[4/12] alice → /alice (should succeed)"
print_info "Envoy's RBAC checks preferred_username == 'alice'"
print_command "curl -H 'Authorization: Bearer \$TOKEN_ALICE' http://localhost:8080/alice"
HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/alice)
echo "HTTP Status: $HTTP_CODE"; cat /tmp/response.txt | jq '{authenticated_user, jwt_claims}'
print_separator
[ "$HTTP_CODE" = "200" ] && print_success "200 — alice owns this route" || print_error "expected 200, got $HTTP_CODE"
pause

# ============================================================
# Step 5: alice -> /bob (DENIED)
# ============================================================
print_header "[5/12] alice → /bob (should FAIL with 403)"
print_info "Authentication ≠ Authorization. Alice is authed, but not Bob."
print_command "curl -si -H 'Authorization: Bearer \$TOKEN_ALICE' http://localhost:8080/bob"
HTTP_CODE=$(curl -si -o /tmp/response.txt -w "%{http_code}" -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/bob)
cat /tmp/response.txt; echo ""
print_separator
[ "$HTTP_CODE" = "403" ] && print_success "403 — RBAC denies cross-user access" || print_error "expected 403, got $HTTP_CODE"
pause

# ============================================================
# Step 6: bob and the admin role
# ============================================================
print_header "[6/12] Authenticate as bob (has admin role)"
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r '.access_token')
[ -n "$TOKEN_BOB" ] && [ "$TOKEN_BOB" != "null" ] || { print_error "no token"; exit 1; }
print_success "Got Bob's JWT"
P=$(echo "$TOKEN_BOB" | cut -d'.' -f2); case $((${#P} % 4)) in 2) P="${P}==" ;; 3) P="${P}=" ;; esac
echo "$P" | base64 -d 2>/dev/null | jq '{username: .preferred_username, roles: .realm_access.roles}'
print_info "Note: Bob has the 'admin' realm role. Watch what that does (or doesn't) buy him..."
pause

print_header "[6b/12] bob → /alice (admin still doesn't help)"
print_command "curl -si -H 'Authorization: Bearer \$TOKEN_BOB' http://localhost:8080/alice"
HTTP_CODE=$(curl -si -o /tmp/response.txt -w "%{http_code}" -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/alice)
cat /tmp/response.txt; echo ""
print_separator
[ "$HTTP_CODE" = "403" ] && print_success "403 — RBAC keys on identity, not roles. Even admin can't impersonate alice." || print_error "expected 403"
pause

# ============================================================
# Step 7: Postgres RLS
# ============================================================
print_header "[7/12] DB queries scoped by JWT identity (Postgres RLS)"
print_info "db-app forwards your identity into Postgres via SET ROLE inside a tx."
print_info "RLS policy: USING (owner = current_user OR owner = 'public')"
echo
print_command "curl -H 'Authorization: Bearer \$TOKEN_ALICE' http://localhost:8080/db | jq .visible_documents"
curl -s -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/db | jq '.visible_documents'
print_separator
print_success "Alice sees alice's rows + the public row. No bob rows visible."
pause

print_command "curl -H 'Authorization: Bearer \$TOKEN_BOB' http://localhost:8080/db | jq .visible_documents"
curl -s -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/db | jq '.visible_documents'
print_separator
print_success "Bob sees bob's rows + public. The DB itself enforces this — even a buggy db-app couldn't leak."
pause

# ============================================================
# Step 8: Grafana OIDC role mapping
# ============================================================
print_header "[8/12] Grafana via OIDC code flow"
print_info "Grafana speaks OIDC natively, so it goes straight to Keycloak — Envoy isn't in this path."
print_info "Realm role 'admin' is mapped to Grafana role 'Admin' via JMESPath:"
echo "    role_attribute_path = contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'"
echo
print_info "Driving the full OAuth code flow with curl (would normally be a browser)..."
WORK=$(mktemp -d)
oauth_login_role() {
  local user="$1" jar html action
  jar=$(mktemp); html=$(mktemp)
  curl -sS -L -c "$jar" -b "$jar" -o "$html" -A "demo" \
    "http://localhost:3300/login/generic_oauth" >/dev/null 2>&1
  action=$(python3 -c '
import sys, re, html as H
s = open(sys.argv[1]).read()
m = re.search(r"<form[^>]+id=\"kc-form-login\"[^>]+action=\"([^\"]+)\"", s) \
    or re.search(r"action=\"([^\"]+)\"[^>]+id=\"kc-form-login\"", s)
print(H.unescape(m.group(1)) if m else "")
' "$html")
  curl -sS -L -c "$jar" -b "$jar" -o /dev/null -A "demo" \
    -d "username=${user}&password=password&credentialId=" "$action"
  curl -sS -b "$jar" "http://localhost:3300/api/user/orgs" \
    | python3 -c 'import sys,json; o=json.load(sys.stdin); print(o[0]["role"] if o else "")' 2>/dev/null
  rm -f "$jar" "$html"
}
ALICE_ROLE=$(oauth_login_role alice)
BOB_ROLE=$(oauth_login_role bob)
echo "  alice -> Grafana role: ${BOLD}${ALICE_ROLE}${NC}"
echo "  bob   -> Grafana role: ${BOLD}${BOB_ROLE}${NC}"
print_separator
[ "$ALICE_ROLE" = "Viewer" ] && [ "$BOB_ROLE" = "Admin" ] \
  && print_success "Same Keycloak realm, different Grafana role — alice=Viewer, bob=Admin" \
  || print_error "unexpected roles"
print_info "(For a real demo, open http://localhost:3300/login in a browser and click 'Sign in with Keycloak'.)"
pause

# ============================================================
# Step 9: SSH cert flow — sign for alice
# ============================================================
print_header "[9/12] SSH-with-Keycloak: sign a 15-min cert for alice"
print_info "ssh-ca takes your JWT + your SSH pubkey, returns a cert with principal = preferred_username."
print_command "ssh-keygen -t ed25519 -f $WORK/alice_id -N ''"
ssh-keygen -t ed25519 -f "$WORK/alice_id" -N "" -q -C "alice-demo"
echo "Generated: $WORK/alice_id and $WORK/alice_id.pub"
pause

print_command "curl -s -X POST -H 'Authorization: Bearer \$TOKEN_ALICE' -H 'Content-Type: text/plain' --data-binary @$WORK/alice_id.pub http://localhost:8080/ssh-ca/sign > $WORK/alice_id-cert.pub"
curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" -H "Content-Type: text/plain" \
  --data-binary @"$WORK/alice_id.pub" http://localhost:8080/ssh-ca/sign > "$WORK/alice_id-cert.pub"
print_info "Cert details (signed by the demo CA):"
ssh-keygen -L -f "$WORK/alice_id-cert.pub" | head -10
pause

# ============================================================
# Step 10: ssh alice@host succeeds
# ============================================================
print_header "[10/12] ssh alice@host with the signed cert (should succeed)"
print_command "ssh -i $WORK/alice_id -p 2222 alice@localhost 'whoami; hostname; cat /etc/os-release | head -2'"
ssh -i "$WORK/alice_id" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
    -p 2222 alice@localhost 'whoami; hostname; cat /etc/os-release | head -2'
print_separator
print_success "Cert principal=alice; sshd's authorized_principals/alice contains 'alice' → allowed"
pause

# ============================================================
# Step 11: alice's cert can't ssh as bob
# ============================================================
print_header "[11/12] Try alice's cert as bob — cross-user impersonation (should FAIL)"
print_command "ssh -i $WORK/alice_id -p 2222 bob@localhost whoami"
ssh -i "$WORK/alice_id" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes \
    -p 2222 bob@localhost whoami
print_separator
print_success "Permission denied — sshd checks principals/bob, finds only 'bob', alice's cert rejected"
pause

# ============================================================
# Step 12: Recap
# ============================================================
print_header "Demo Complete — recap"
echo -e "${GREEN}One Keycloak identity, four enforcement points:${NC}"
echo "  1. ${BOLD}HTTP${NC}    — Envoy RBAC by JWT preferred_username"
echo "  2. ${BOLD}DB${NC}      — Postgres RLS, current_user from SET ROLE"
echo "  3. ${BOLD}Grafana${NC} — OIDC code flow + JMESPath role mapping"
echo "  4. ${BOLD}SSH${NC}     — short-lived CA-signed certs with principal = JWT user"
echo
echo -e "${YELLOW}What's enforced where:${NC}"
echo "  - Envoy:   reject anon HTTP (401), wrong-user HTTP (403)"
echo "  - DB:      RLS in Postgres — even a compromised db-app can't leak rows"
echo "  - Grafana: OIDC, no shared secrets between Grafana and apps"
echo "  - sshd:    cert validity (15m) + principals match — no long-lived keys, no passwords"
echo
print_success "Identity-aware, zero-trust security across heterogeneous backends."

rm -rf "$WORK" /tmp/response.txt 2>/dev/null
