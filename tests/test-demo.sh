#!/bin/bash

# Integration tests for the reverse proxy demo
# Run this script to validate the demo is working correctly

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Function to decode JWT payload with proper padding
decode_jwt_payload() {
    local token=$1
    local payload=$(echo "$token" | cut -d'.' -f2)
    # Add padding for base64 decode
    case $((${#payload} % 4)) in
      2) payload="${payload}==" ;;
      3) payload="${payload}=" ;;
    esac
    echo "$payload" | base64 -d 2>/dev/null
}

# Function to print test results
print_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC}: $2"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: $2"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Running Integration Tests${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    exit 1
fi

# Test 1: Check all services are running
echo -e "${YELLOW}[Test Suite 1: Service Health]${NC}"
RUNNING_SERVICES=$(docker compose ps --status running 2>/dev/null)
if echo "$RUNNING_SERVICES" | grep -q "demo-keycloak" && \
   echo "$RUNNING_SERVICES" | grep -q "demo-envoy" && \
   echo "$RUNNING_SERVICES" | grep -q "demo-public-app" && \
   echo "$RUNNING_SERVICES" | grep -q "demo-alice-app" && \
   echo "$RUNNING_SERVICES" | grep -q "demo-bob-app"; then
    print_test 0 "All services are running"
else
    print_test 1 "All services are running"
    echo "Please run: docker compose up -d"
    exit 1
fi

# Test 2: Keycloak is ready
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8180/realms/demo)
if [ "$HTTP_CODE" == "200" ]; then
    print_test 0 "Keycloak realm is accessible"
else
    print_test 1 "Keycloak realm is accessible (got HTTP $HTTP_CODE)"
fi

# Test 3: Envoy is ready
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "401" ]; then
    print_test 0 "Envoy proxy is accessible"
else
    print_test 1 "Envoy proxy is accessible (got HTTP $HTTP_CODE)"
fi

echo ""
echo -e "${YELLOW}[Test Suite 2: Unauthenticated Access]${NC}"

# Test 4: Unauthenticated request to /public should fail with 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/public)
if [ "$HTTP_CODE" == "401" ]; then
    print_test 0 "Unauthenticated access to /public returns 401"
else
    print_test 1 "Unauthenticated access to /public returns 401 (got $HTTP_CODE)"
fi

# Test 5: Unauthenticated request to /alice should fail with 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/alice)
if [ "$HTTP_CODE" == "401" ]; then
    print_test 0 "Unauthenticated access to /alice returns 401"
else
    print_test 1 "Unauthenticated access to /alice returns 401 (got $HTTP_CODE)"
fi

# Test 6: Unauthenticated request to /bob should fail with 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/bob)
if [ "$HTTP_CODE" == "401" ]; then
    print_test 0 "Unauthenticated access to /bob returns 401"
else
    print_test 1 "Unauthenticated access to /bob returns 401 (got $HTTP_CODE)"
fi

echo ""
echo -e "${YELLOW}[Test Suite 3: Alice Authentication]${NC}"

# Test 7: Can get token for Alice
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=alice" \
  -d "password=password" \
  -d "grant_type=password" \
  -d "client_id=demo-client" \
  | jq -r '.access_token')

if [ -n "$TOKEN_ALICE" ] && [ "$TOKEN_ALICE" != "null" ]; then
    print_test 0 "Can authenticate as Alice and get JWT token"
else
    print_test 1 "Can authenticate as Alice and get JWT token"
    exit 1
fi

# Test 8: Alice's token contains expected claims
USERNAME=$(decode_jwt_payload "$TOKEN_ALICE" | jq -r '.preferred_username')
ROLES=$(decode_jwt_payload "$TOKEN_ALICE" | jq -r '.realm_access.roles[]')

if [ "$USERNAME" == "alice" ]; then
    print_test 0 "Alice's token contains correct username"
else
    print_test 1 "Alice's token contains correct username (got $USERNAME)"
fi

if echo "$ROLES" | grep -q "user"; then
    print_test 0 "Alice's token contains 'user' role"
else
    print_test 1 "Alice's token contains 'user' role"
fi

echo ""
echo -e "${YELLOW}[Test Suite 4: Alice Authorization]${NC}"

# Test 9: Alice can access /public
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  http://localhost:8080/public)

if [ "$HTTP_CODE" == "200" ]; then
    print_test 0 "Alice can access /public (200 OK)"
else
    print_test 1 "Alice can access /public (got $HTTP_CODE)"
fi

# Test 10: Alice's request to /public returns correct user info
RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/public)
RESPONSE_USER=$(echo "$RESPONSE" | jq -r '.jwt_claims.username // .authenticated_user')

if [ "$RESPONSE_USER" == "alice" ]; then
    print_test 0 "Public app correctly identifies Alice"
else
    print_test 1 "Public app correctly identifies Alice (got $RESPONSE_USER)"
fi

# Test 11: Alice can access /alice
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  http://localhost:8080/alice)

if [ "$HTTP_CODE" == "200" ]; then
    print_test 0 "Alice can access /alice (200 OK)"
else
    print_test 1 "Alice can access /alice (got $HTTP_CODE)"
fi

# Test 12: Alice's request to /alice returns correct user info
RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/alice)
RESPONSE_USER=$(echo "$RESPONSE" | jq -r '.jwt_claims.username // .authenticated_user')

if [ "$RESPONSE_USER" == "alice" ]; then
    print_test 0 "Alice app correctly identifies Alice"
else
    print_test 1 "Alice app correctly identifies Alice (got $RESPONSE_USER)"
fi

# Test 13: Alice cannot access /bob
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  http://localhost:8080/bob)

if [ "$HTTP_CODE" == "403" ]; then
    print_test 0 "Alice blocked from /bob (403 Forbidden)"
else
    print_test 1 "Alice blocked from /bob (got $HTTP_CODE, expected 403)"
fi

echo ""
echo -e "${YELLOW}[Test Suite 5: Bob Authentication]${NC}"

# Test 14: Can get token for Bob
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=bob" \
  -d "password=password" \
  -d "grant_type=password" \
  -d "client_id=demo-client" \
  | jq -r '.access_token')

if [ -n "$TOKEN_BOB" ] && [ "$TOKEN_BOB" != "null" ]; then
    print_test 0 "Can authenticate as Bob and get JWT token"
else
    print_test 1 "Can authenticate as Bob and get JWT token"
    exit 1
fi

# Test 15: Bob's token contains expected roles
ROLES=$(decode_jwt_payload "$TOKEN_BOB" | jq -r '.realm_access.roles[]')

if echo "$ROLES" | grep -q "user"; then
    print_test 0 "Bob's token contains 'user' role"
else
    print_test 1 "Bob's token contains 'user' role"
fi

if echo "$ROLES" | grep -q "admin"; then
    print_test 0 "Bob's token contains 'admin' role"
else
    print_test 1 "Bob's token contains 'admin' role"
fi

echo ""
echo -e "${YELLOW}[Test Suite 6: Bob Authorization]${NC}"

# Test 16: Bob can access /public
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  http://localhost:8080/public)

if [ "$HTTP_CODE" == "200" ]; then
    print_test 0 "Bob can access /public (200 OK)"
else
    print_test 1 "Bob can access /public (got $HTTP_CODE)"
fi

# Test 17: Bob can access /bob
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  http://localhost:8080/bob)

if [ "$HTTP_CODE" == "200" ]; then
    print_test 0 "Bob can access /bob (200 OK)"
else
    print_test 1 "Bob can access /bob (got $HTTP_CODE)"
fi

# Test 18: Bob app correctly identifies Bob
RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/bob)
RESPONSE_USER=$(echo "$RESPONSE" | jq -r '.jwt_claims.username // .authenticated_user')

if [ "$RESPONSE_USER" == "bob" ]; then
    print_test 0 "Bob app correctly identifies Bob"
else
    print_test 1 "Bob app correctly identifies Bob (got $RESPONSE_USER)"
fi

# Test 19: Bob cannot access /alice
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  http://localhost:8080/alice)

if [ "$HTTP_CODE" == "403" ]; then
    print_test 0 "Bob blocked from /alice (403 Forbidden)"
else
    print_test 1 "Bob blocked from /alice (got $HTTP_CODE, expected 403)"
fi

echo ""
echo -e "${YELLOW}[Test Suite 7: Access Logging]${NC}"

# Test 20: Access logs contain user identity
if docker compose logs envoy 2>/dev/null | grep -q "alice"; then
    print_test 0 "Access logs contain user identity (alice)"
else
    print_test 1 "Access logs contain user identity (alice)"
fi

# Test 21: Access logs contain role information
if docker compose logs envoy 2>/dev/null | grep -q "roles"; then
    print_test 0 "Access logs contain role information"
else
    print_test 1 "Access logs contain role information"
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Total Tests:  $TESTS_RUN"
echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed! Demo is ready.${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. Please review the output above.${NC}"
    exit 1
fi
