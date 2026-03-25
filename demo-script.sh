#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    clear
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Function to print a visual separator
print_separator() {
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo ""
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print error messages
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Function to print info messages
print_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

# Function to print commands being executed (pauses before running)
print_command() {
    echo ""
    echo -e "${BOLD}${MAGENTA}  \$ $1${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}▶ [Press Enter to run]${NC}"
    read -r
}

# Function to pause until user presses Enter
pause() {
    echo ""
    echo -e "${MAGENTA}→ [Press Enter to continue]${NC}"
    read -r
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    print_error "jq is not installed. Please install it first: brew install jq"
    exit 1
fi

# Check if services are running
print_header "[0/10] Verify Services"
print_info "Checking all services are running..."
if ! docker-compose ps | grep -q "Up"; then
    print_error "Services are not running. Please run: docker-compose up -d"
    exit 1
fi
print_success "All services are running"
pause

# Step 1: Unauthenticated Access
print_header "[1/10] Unauthenticated Access (Should Fail)"
print_info "Without a valid JWT token, all requests are blocked..."
print_command "curl -si http://localhost:8080/public"
HTTP_CODE=$(curl -si -o /tmp/response.txt -w "%{http_code}" http://localhost:8080/public)
cat /tmp/response.txt
echo ""
print_separator
if [ "$HTTP_CODE" == "401" ]; then
    print_success "Request blocked as expected (401 Unauthorized)"
else
    print_error "Expected 401, got $HTTP_CODE"
fi
pause

# Step 2: Authenticate as Alice
print_header "[2/10] Authenticate as Alice"
print_info "Getting JWT token for alice..."
print_command "curl -s -X POST http://localhost:8180/realms/demo/protocol/openid-connect/token \\\\\n    -H 'Content-Type: application/x-www-form-urlencoded' \\\\\n    -d 'username=alice' \\\\\n    -d 'password=password' \\\\\n    -d 'grant_type=password' \\\\\n    -d 'client_id=demo-client'"

TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=alice" \
  -d "password=password" \
  -d "grant_type=password" \
  -d "client_id=demo-client" \
  | jq -r '.access_token')

if [ -z "$TOKEN_ALICE" ] || [ "$TOKEN_ALICE" == "null" ]; then
    print_error "Failed to get token for Alice"
    exit 1
fi

print_success "Token obtained for Alice"
echo "Token: $TOKEN_ALICE"
pause

print_info "Decoding Alice's JWT token to see claims..."
# Extract and decode JWT payload (add padding if needed)
PAYLOAD=$(echo "$TOKEN_ALICE" | cut -d'.' -f2)
case $((${#PAYLOAD} % 4)) in
  2) PAYLOAD="${PAYLOAD}==" ;;
  3) PAYLOAD="${PAYLOAD}=" ;;
esac
echo "$PAYLOAD" | base64 -d 2>/dev/null | jq '.' || echo "(Token claims visible in responses below)"
pause

# Step 3: Alice Accesses Public App
print_header "[3/10] Alice → Public App (Should Succeed)"
print_info "Alice attempts to access the public app..."
print_command "curl \\\\\n    -H 'Authorization: Bearer \$TOKEN_ALICE' \\\\\n    http://localhost:8080/public"

HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  http://localhost:8080/public)

echo "HTTP Status: $HTTP_CODE"
cat /tmp/response.txt | jq '.'
print_separator
if [ "$HTTP_CODE" == "200" ]; then
    print_success "Alice can access public app!"
else
    print_error "Expected 200, got $HTTP_CODE"
fi
pause

# Step 4: Alice Accesses Her Own App
print_header "[4/10] Alice → Alice's App (Should Succeed)"
print_info "Alice attempts to access HER OWN private app..."
print_command "curl \\\\\n    -H 'Authorization: Bearer \$TOKEN_ALICE' \\\\\n    http://localhost:8080/alice"

HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  http://localhost:8080/alice)

echo "HTTP Status: $HTTP_CODE"
cat /tmp/response.txt | jq '.'
print_separator
if [ "$HTTP_CODE" == "200" ]; then
    print_success "Alice can access her own app! ✓"
else
    print_error "Expected 200, got $HTTP_CODE"
fi
pause

# Step 5: Alice Tries to Access Bob's App
print_header "[5/10] Alice → Bob's App (Should FAIL)"
print_info "Alice attempts to access BOB'S private app..."
print_command "curl -si \\\\\n    -H 'Authorization: Bearer \$TOKEN_ALICE' \\\\\n    http://localhost:8080/bob"

HTTP_CODE=$(curl -si -o /tmp/response.txt -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  http://localhost:8080/bob)

cat /tmp/response.txt
echo ""
print_separator
if [ "$HTTP_CODE" == "403" ]; then
    print_success "Alice blocked from Bob's app (403 Forbidden) ✓"
    print_info "She's authenticated, but not authorized (not Bob!)"
else
    print_error "Expected 403, got $HTTP_CODE"
fi
pause

# Step 6: Authenticate as Bob
print_header "[6/10] Authenticate as Bob"
print_info "Getting JWT token for bob..."
print_command "curl -s -X POST http://localhost:8180/realms/demo/protocol/openid-connect/token \\\\\n    -H 'Content-Type: application/x-www-form-urlencoded' \\\\\n    -d 'username=bob' \\\\\n    -d 'password=password' \\\\\n    -d 'grant_type=password' \\\\\n    -d 'client_id=demo-client'"

TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=bob" \
  -d "password=password" \
  -d "grant_type=password" \
  -d "client_id=demo-client" \
  | jq -r '.access_token')

if [ -z "$TOKEN_BOB" ] || [ "$TOKEN_BOB" == "null" ]; then
    print_error "Failed to get token for Bob"
    exit 1
fi

print_success "Token obtained for Bob"
echo "Token: $TOKEN_BOB"
pause

# Step 7: Bob Accesses Public App
print_header "[7/10] Bob → Public App (Should Succeed)"
print_info "Bob attempts to access the public app..."
print_command "curl \\\\\n    -H 'Authorization: Bearer \$TOKEN_BOB' \\\\\n    http://localhost:8080/public"

HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  http://localhost:8080/public)

echo "HTTP Status: $HTTP_CODE"
cat /tmp/response.txt | jq '.'
print_separator
if [ "$HTTP_CODE" == "200" ]; then
    print_success "Bob can access public app!"
else
    print_error "Expected 200, got $HTTP_CODE"
fi
pause

# Step 8: Bob Tries to Access Alice's App
print_header "[8/10] Bob → Alice's App (Should FAIL)"
print_info "Bob attempts to access ALICE'S private app..."
print_command "curl -si \\\\\n    -H 'Authorization: Bearer \$TOKEN_BOB' \\\\\n    http://localhost:8080/alice"

HTTP_CODE=$(curl -si -o /tmp/response.txt -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  http://localhost:8080/alice)

cat /tmp/response.txt
echo ""
print_separator
if [ "$HTTP_CODE" == "403" ]; then
    print_success "Bob blocked from Alice's app (403 Forbidden) ✓"
    print_info "He's authenticated, but not authorized (not Alice!)"
else
    print_error "Expected 403, got $HTTP_CODE"
fi
pause

# Step 9: Bob Accesses His Own App
print_header "[9/10] Bob → Bob's App (Should Succeed)"
print_info "Bob attempts to access HIS OWN private app..."
print_command "curl \\\\\n    -H 'Authorization: Bearer \$TOKEN_BOB' \\\\\n    http://localhost:8080/bob"

HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  http://localhost:8080/bob)

echo "HTTP Status: $HTTP_CODE"
cat /tmp/response.txt | jq '.'
print_separator
if [ "$HTTP_CODE" == "200" ]; then
    print_success "Bob can access his own app! ✓"
else
    print_error "Expected 200, got $HTTP_CODE"
fi
pause

# Step 10: View Access Logs
print_header "[10/10] Access Logs (Complete Audit Trail)"
print_info "Checking Envoy access logs for identity information..."
print_command "docker-compose logs envoy --tail=20"
echo ""
docker-compose logs envoy --tail=20
echo ""
print_separator
print_success "Every request is logged with user identity and authorization decision"
pause

# Summary
print_header "Demo Complete!"
echo -e "${GREEN}Key Takeaways:${NC}"
echo "1. ✓ Authentication: All requests require valid JWT tokens"
echo "2. ✓ Identity-Based Authorization: Per-user access control"
echo "   • Alice can access: /public, /alice (NOT /bob)"
echo "   • Bob can access: /public, /bob (NOT /alice)"
echo "3. ✓ Least Privilege: Users get exactly what they need, nothing more"
echo "4. ✓ Audit Trail: All access logged with identity context"
echo ""
echo -e "${YELLOW}Compare this to VPNs:${NC}"
echo "- VPN: Once inside, access everything (network-level trust)"
echo "- Reverse Proxy: Every request validated, per-user authorization"
echo ""
print_success "This is identity-aware, zero-trust security!"

# Cleanup temp file
rm -f /tmp/response.txt
