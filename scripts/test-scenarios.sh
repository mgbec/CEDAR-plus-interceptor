#!/usr/bin/env bash
# =============================================================
# End-to-end test script for the multi-tenant database agent.
#
# Tests Cedar policy enforcement and rate limiting across all
# three roles (admin, engineering, marketing).
#
# Usage:
#   ./scripts/test-scenarios.sh <gateway-url>
#
# Prerequisites:
#   - Terraform applied (Cognito + Lambdas deployed)
#   - agentcore deploy completed (Gateway live)
#   - jq installed
# =============================================================

set -euo pipefail

GATEWAY_URL="${1:?Usage: $0 <gateway-url>}"
SCRIPT_DIR="$(dirname "$0")"
PASSWORD="${TEST_PASSWORD:-TestPass1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; }
info() { echo -e "${YELLOW}→${NC} $1"; }

# Helper: call a tool via the gateway
call_tool() {
  local token="$1"
  local tool_name="$2"
  local args="$3"

  curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"method\": \"tools/call\", \"params\": {\"name\": \"${tool_name}\", \"arguments\": ${args}}}"
}

# Extract HTTP status from curl output
get_status() {
  echo "$1" | tail -1
}

# Extract body from curl output
get_body() {
  echo "$1" | sed '$d'
}

echo "=============================================="
echo " Multi-Tenant DB Agent — Integration Tests"
echo "=============================================="
echo ""
echo "Gateway: ${GATEWAY_URL}"
echo ""

# --- Get tokens for each role ---
info "Authenticating test users..."

ADMIN_TOKEN=$("$SCRIPT_DIR/get-token.sh" "admin@example.com" "$PASSWORD" 2>/dev/null)
ENGINEER_TOKEN=$("$SCRIPT_DIR/get-token.sh" "engineer@example.com" "$PASSWORD" 2>/dev/null)
MARKETING_TOKEN=$("$SCRIPT_DIR/get-token.sh" "marketing@example.com" "$PASSWORD" 2>/dev/null)

echo ""
echo "=== Test 1: Cedar Policy — Admin Full Access ==="
echo ""

info "Admin calling list_tables..."
RESULT=$(call_tool "$ADMIN_TOKEN" "DatabaseTools___list_tables" '{"database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "200" ]] && pass "Admin can list tables (HTTP $STATUS)" || fail "Admin list_tables returned HTTP $STATUS"

info "Admin calling delete_records..."
RESULT=$(call_tool "$ADMIN_TOKEN" "DatabaseTools___delete_records" '{"table": "users", "condition": "id > 1000", "database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "200" ]] && pass "Admin can delete records (HTTP $STATUS)" || fail "Admin delete_records returned HTTP $STATUS"

echo ""
echo "=== Test 2: Cedar Policy — Engineering Restricted ==="
echo ""

info "Engineer calling run_query..."
RESULT=$(call_tool "$ENGINEER_TOKEN" "DatabaseTools___run_query" '{"sql": "SELECT * FROM users LIMIT 10", "database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "200" ]] && pass "Engineer can run queries (HTTP $STATUS)" || fail "Engineer run_query returned HTTP $STATUS"

info "Engineer calling delete_records (should be DENIED by Cedar)..."
RESULT=$(call_tool "$ENGINEER_TOKEN" "DatabaseTools___delete_records" '{"table": "users", "condition": "id > 1000", "database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "403" ]] && pass "Engineer denied delete_records (HTTP $STATUS)" || fail "Expected 403, got HTTP $STATUS"

echo ""
echo "=== Test 3: Cedar Policy — Marketing Limited ==="
echo ""

info "Marketing calling list_tables..."
RESULT=$(call_tool "$MARKETING_TOKEN" "DatabaseTools___list_tables" '{"database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "200" ]] && pass "Marketing can list tables (HTTP $STATUS)" || fail "Marketing list_tables returned HTTP $STATUS"

info "Marketing calling run_query (should be DENIED by Cedar)..."
RESULT=$(call_tool "$MARKETING_TOKEN" "DatabaseTools___run_query" '{"sql": "SELECT * FROM users", "database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "403" ]] && pass "Marketing denied run_query (HTTP $STATUS)" || fail "Expected 403, got HTTP $STATUS"

info "Marketing calling delete_records (should be DENIED by Cedar)..."
RESULT=$(call_tool "$MARKETING_TOKEN" "DatabaseTools___delete_records" '{"table": "users", "condition": "id > 1000", "database": "analytics"}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "403" ]] && pass "Marketing denied delete_records (HTTP $STATUS)" || fail "Expected 403, got HTTP $STATUS"

echo ""
echo "=== Test 4: Rate Limiting — Exhaust Marketing Quota ==="
echo ""

info "Sending 25 rapid requests as marketing (limit is 20/hr)..."
RATE_LIMITED=false
for i in $(seq 1 25); do
  RESULT=$(call_tool "$MARKETING_TOKEN" "DatabaseTools___list_tables" '{"database": "analytics"}')
  STATUS=$(get_status "$RESULT")
  if [[ "$STATUS" == "429" ]]; then
    pass "Rate limited after $i requests (HTTP 429)"
    RATE_LIMITED=true
    BODY=$(get_body "$RESULT")
    echo "     Response: $(echo "$BODY" | jq -r '.error // .message // .' 2>/dev/null || echo "$BODY")"
    break
  fi
done

if [[ "$RATE_LIMITED" == "false" ]]; then
  fail "Expected rate limiting after 20 requests, but all 25 succeeded"
fi

echo ""
echo "=== Test 5: Unauthenticated Request ==="
echo ""

info "Calling without a token (should be rejected by authorizer)..."
RESULT=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method": "tools/call", "params": {"name": "DatabaseTools___list_tables", "arguments": {"database": "analytics"}}}')
STATUS=$(get_status "$RESULT")
[[ "$STATUS" == "401" ]] && pass "Unauthenticated request rejected (HTTP $STATUS)" || fail "Expected 401, got HTTP $STATUS"

echo ""
echo "=============================================="
echo " Tests Complete"
echo "=============================================="
