#!/usr/bin/env bash
# =============================================================================
# 15-test-device-management.sh — Device Management API verification for Cenotoo
#
# Tests the Device Management feature on a running k3s cluster:
#   1. Preflight checks (tools, auth env)
#   2. API authentication
#   3. Test project + collection setup
#   4. Device registration (POST /devices)
#   5. List devices (GET /devices) with pagination
#   6. Get device by ID (GET /devices/{id})
#   7. Update device metadata (PUT /devices/{id})
#   8. Device shadow: set desired state
#   9. Device shadow: update reported state
#  10. Device shadow: get shadow + delta verification
#  11. Auth enforcement (unauthenticated, read-only key rejected for writes)
#  12. 404 for unknown device
#  13. Device deletion (DELETE /devices/{id})
#  14. Cleanup
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username     (default: admin)
#   CENOTOO_ADMIN_PASSWORD   API admin password     (required — no default)
#
# Prerequisites:
#   - jq, curl, kubectl
#   - Cenotoo deployed (07), API deployed (08)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/15-test-device-management.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="dev-$(date +%s)"
TEST_PROJECT="devtest${RUN_ID##dev-}"
TEST_COLLECTION="readings"

API_PORT=8000
API_BASE="http://localhost:${API_PORT}/api/v1"

passed=0
failed=0

pass()  { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()  { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()  { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header(){ printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

PF_API_PID=""
PROJECT_ID=""
COLLECTION_ID=""
DEVICE_ID=""
API_TOKEN=""
READ_KEY=""
WRITE_KEY=""
MASTER_KEY=""
_RESP_FILE="/tmp/cenotoo_dev_test_resp_$$.json"

cleanup() {
    info "Cleaning up ..."
    if [ -n "${PROJECT_ID:-}" ] && [ -n "${API_TOKEN:-}" ]; then
        curl -s -X DELETE \
            "${API_BASE}/projects/${PROJECT_ID}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            >/dev/null 2>&1 || true
        info "Deleted test project $PROJECT_ID"
    fi
    [ -n "${PF_API_PID:-}" ] && kill "$PF_API_PID" 2>/dev/null || true
    rm -f "$_RESP_FILE" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

_api() {
    local method="$1" url="$2"; shift 2
    local http
    http=$(curl -s -o "$_RESP_FILE" -w "%{http_code}" -X "$method" "$url" "$@" 2>/dev/null || echo "000")
    echo "$http"
}

# ---------------------------------------------------------------------------
header "Preflight"
# ---------------------------------------------------------------------------
for cmd in jq curl kubectl; do
    if command -v "$cmd" &>/dev/null; then
        pass "Command available: $cmd"
    else
        fail "Command not found: $cmd"
    fi
done

if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    fail "CENOTOO_ADMIN_PASSWORD is not set"
    printf '\n\033[1;31mRun: CENOTOO_ADMIN_PASSWORD=<pass> %s\033[0m\n' "$0"
    exit 1
fi
pass "CENOTOO_ADMIN_PASSWORD is set"

if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    fail "Namespace $NAMESPACE not found"
    exit 1
fi
pass "Namespace $NAMESPACE exists"

# ---------------------------------------------------------------------------
header "Port-Forward Setup"
# ---------------------------------------------------------------------------
API_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$API_SVC" ]; then
    fail "Cannot find cenotoo-api Service in namespace $NAMESPACE"
    exit 1
fi

pkill -f "kubectl port-forward.*${API_PORT}:8000" 2>/dev/null || true
sleep 1

info "Port-forwarding API service $API_SVC → localhost:${API_PORT} ..."
kubectl port-forward "svc/${API_SVC}" "${API_PORT}:8000" -n "$NAMESPACE" &>/dev/null &
PF_API_PID=$!

_elapsed=0
until curl -s "http://localhost:${API_PORT}/health" &>/dev/null; do
    sleep 1
    _elapsed=$((_elapsed + 1))
    if [ "$_elapsed" -ge 15 ]; then
        fail "API not responding on port ${API_PORT} after 15s"
        exit 1
    fi
done
pass "API port-forward active and healthy (pid $PF_API_PID)"

# ---------------------------------------------------------------------------
header "API Authentication & Setup"
# ---------------------------------------------------------------------------
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD}"

AUTH_HTTP=$(_api POST "${API_BASE}/token" \
    -d "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}")
if [ "$AUTH_HTTP" = "200" ]; then
    API_TOKEN=$(jq -r '.access_token // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "null" ]; then
        pass "API authentication successful"
    else
        fail "API auth: got 200 but no access_token"
        exit 1
    fi
else
    fail "API authentication failed (HTTP $AUTH_HTTP)"
    exit 1
fi

info "Creating test project: $TEST_PROJECT ..."
PROJ_HTTP=$(_api POST "${API_BASE}/projects" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"Device management test\", \"tags\": [\"test\"]}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
        pass "Test project created: $PROJECT_ID"
    else
        fail "Project created but no ID in response"
        exit 1
    fi
else
    fail "Project creation failed (HTTP $PROJ_HTTP): $(cat "$_RESP_FILE")"
    exit 1
fi

info "Creating test collection: $TEST_COLLECTION ..."
COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"Device test collection\", \"tags\": [\"test\"], \"collection_schema\": {\"value\": \"float\"}}")
if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
    COLLECTION_ID=$(curl -s "${API_BASE}/projects/${PROJECT_ID}/collections" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        | jq -r --arg name "$TEST_COLLECTION" '.items[] | select(.collection_name==$name) | .collection_id // ""' 2>/dev/null || echo "")
    pass "Test collection created (HTTP $COLL_HTTP)"
else
    fail "Collection creation failed (HTTP $COLL_HTTP)"
fi

info "Creating API keys ..."
READ_KEY_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"key_type": "read"}')
READ_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

WRITE_KEY_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"key_type": "write"}')
WRITE_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

MASTER_KEY_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"key_type": "master"}')
MASTER_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

if [ -n "$READ_KEY" ] && [ -n "$WRITE_KEY" ] && [ -n "$MASTER_KEY" ]; then
    pass "API keys created (read, write, master)"
else
    fail "Failed to create one or more API keys"
fi

# ---------------------------------------------------------------------------
header "TEST_01: Register Device (POST /devices)"
# ---------------------------------------------------------------------------
REG_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/devices" \
    -H "X-API-Key: ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"sensor-${RUN_ID}\", \"description\": \"Test sensor\", \"tags\": [\"test\", \"sensor\"]}")
if [ "$REG_HTTP" = "200" ] || [ "$REG_HTTP" = "201" ]; then
    DEVICE_ID=$(jq -r '.id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    DEVICE_STATUS=$(jq -r '.status // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$DEVICE_ID" ] && [ "$DEVICE_ID" != "null" ]; then
        pass "TEST_01: Device registered: $DEVICE_ID (status=$DEVICE_STATUS)"
    else
        fail "TEST_01: Device registered (HTTP $REG_HTTP) but no id in response"
    fi
else
    fail "TEST_01: Device registration failed (HTTP $REG_HTTP): $(cat "$_RESP_FILE")"
fi

# ---------------------------------------------------------------------------
header "TEST_02: List Devices (GET /devices)"
# ---------------------------------------------------------------------------
LIST_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/devices" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$LIST_HTTP" = "200" ]; then
    TOTAL=$(jq -r '.total // 0' "$_RESP_FILE" 2>/dev/null || echo "0")
    if [ "$TOTAL" -ge 1 ]; then
        pass "TEST_02: List devices returned $TOTAL device(s)"
    else
        fail "TEST_02: List devices returned total=$TOTAL (expected ≥1)"
    fi
else
    fail "TEST_02: List devices failed (HTTP $LIST_HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_03: Get Device by ID (GET /devices/{id})"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    GET_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}" \
        -H "X-API-Key: ${READ_KEY}")
    if [ "$GET_HTTP" = "200" ]; then
        RETURNED_ID=$(jq -r '.id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ "$RETURNED_ID" = "$DEVICE_ID" ]; then
            pass "TEST_03: Get device returned correct ID"
        else
            fail "TEST_03: Get device returned wrong ID: $RETURNED_ID"
        fi
    else
        fail "TEST_03: Get device failed (HTTP $GET_HTTP)"
    fi
else
    info "TEST_03: Skipping (no device ID from TEST_01)"
fi

# ---------------------------------------------------------------------------
header "TEST_04: Update Device Metadata (PUT /devices/{id})"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    UPD_HTTP=$(_api PUT "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"description": "Updated description", "status": "inactive"}')
    if [ "$UPD_HTTP" = "200" ]; then
        NEW_STATUS=$(jq -r '.status // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ "$NEW_STATUS" = "inactive" ]; then
            pass "TEST_04: Device updated, status=$NEW_STATUS"
        else
            fail "TEST_04: Update returned status='$NEW_STATUS' (expected 'inactive')"
        fi
    else
        fail "TEST_04: Update device failed (HTTP $UPD_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_04: Skipping (no device ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_05: Set Desired State (PUT /shadow/desired)"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    DES_HTTP=$(_api PUT "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}/shadow/desired" \
        -H "X-API-Key: ${WRITE_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"state": {"mode": "active", "threshold": 25.0}}')
    if [ "$DES_HTTP" = "200" ]; then
        MSG=$(jq -r '.message // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        pass "TEST_05: Desired state set ($MSG)"
    else
        fail "TEST_05: Set desired state failed (HTTP $DES_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_05: Skipping (no device ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_06: Update Reported State (PUT /shadow/reported)"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    REP_HTTP=$(_api PUT "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}/shadow/reported" \
        -H "X-API-Key: ${WRITE_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"state": {"mode": "idle", "threshold": 25.0}}')
    if [ "$REP_HTTP" = "200" ]; then
        pass "TEST_06: Reported state updated"
    else
        fail "TEST_06: Update reported state failed (HTTP $REP_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_06: Skipping (no device ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_07: Get Shadow + Delta Verification (GET /shadow)"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    SHADOW_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}/shadow" \
        -H "X-API-Key: ${READ_KEY}")
    if [ "$SHADOW_HTTP" = "200" ]; then
        REPORTED_MODE=$(jq -r '.reported.mode // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        DESIRED_MODE=$(jq -r '.desired.mode // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        DELTA_MODE=$(jq -r '.delta.mode // "NONE"' "$_RESP_FILE" 2>/dev/null || echo "NONE")

        if [ "$REPORTED_MODE" = "idle" ] && [ "$DESIRED_MODE" = "active" ]; then
            pass "TEST_07: Shadow reported=$REPORTED_MODE desired=$DESIRED_MODE"
        else
            fail "TEST_07: Unexpected shadow values (reported=$REPORTED_MODE, desired=$DESIRED_MODE)"
        fi

        if [ "$DELTA_MODE" = "active" ]; then
            pass "TEST_07: Delta correctly identifies mode divergence (delta.mode=$DELTA_MODE)"
        else
            fail "TEST_07: Delta missing mode divergence (delta.mode=$DELTA_MODE, expected 'active')"
        fi
    else
        fail "TEST_07: Get shadow failed (HTTP $SHADOW_HTTP)"
    fi
else
    info "TEST_07: Skipping (no device ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_08: Auth Enforcement"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    UNAUTH_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/devices" 2>/dev/null || echo "000")
    if [ "$UNAUTH_HTTP" = "401" ] || [ "$UNAUTH_HTTP" = "403" ]; then
        pass "TEST_08a: Unauthenticated list devices rejected (HTTP $UNAUTH_HTTP)"
    else
        fail "TEST_08a: Unauthenticated list devices accepted (HTTP $UNAUTH_HTTP)"
    fi

    READ_DEL_HTTP=$(_api DELETE "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}" \
        -H "X-API-Key: ${READ_KEY}")
    if [ "$READ_DEL_HTTP" = "403" ]; then
        pass "TEST_08b: Read key correctly rejected for DELETE (HTTP $READ_DEL_HTTP)"
    else
        fail "TEST_08b: Read key DELETE returned HTTP $READ_DEL_HTTP (expected 403)"
    fi

    WRITE_REG_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/devices" \
        -H "X-API-Key: ${WRITE_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"name": "should-fail"}')
    if [ "$WRITE_REG_HTTP" = "403" ]; then
        pass "TEST_08c: Write key correctly rejected for POST /devices (HTTP $WRITE_REG_HTTP)"
    else
        fail "TEST_08c: Write key POST /devices returned HTTP $WRITE_REG_HTTP (expected 403)"
    fi
else
    info "TEST_08: Skipping auth tests (no device ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_09: 404 for Unknown Device"
# ---------------------------------------------------------------------------
FAKE_ID="00000000-0000-0000-0000-000000000099"
NOT_FOUND_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/devices/${FAKE_ID}" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$NOT_FOUND_HTTP" = "404" ]; then
    pass "TEST_09: Unknown device returns 404"
else
    fail "TEST_09: Unknown device returned HTTP $NOT_FOUND_HTTP (expected 404)"
fi

# ---------------------------------------------------------------------------
header "TEST_10: Delete Device (DELETE /devices/{id})"
# ---------------------------------------------------------------------------
if [ -n "${DEVICE_ID:-}" ] && [ "$DEVICE_ID" != "null" ]; then
    DEL_HTTP=$(_api DELETE "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}" \
        -H "X-API-Key: ${MASTER_KEY}")
    if [ "$DEL_HTTP" = "200" ]; then
        pass "TEST_10: Device deleted (HTTP $DEL_HTTP)"
        VERIFY_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/devices/${DEVICE_ID}" \
            -H "X-API-Key: ${READ_KEY}")
        if [ "$VERIFY_HTTP" = "404" ]; then
            pass "TEST_10: Deleted device correctly returns 404"
        else
            fail "TEST_10: Deleted device still accessible (HTTP $VERIFY_HTTP)"
        fi
    else
        fail "TEST_10: Delete device failed (HTTP $DEL_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_10: Skipping (no device ID)"
fi

# ---------------------------------------------------------------------------
header "Summary"
# ---------------------------------------------------------------------------
rm -f "$_RESP_FILE"
total=$((passed + failed))
printf '\n  \033[1;32m%d passed\033[0m' "$passed"
if [ "$failed" -gt 0 ]; then
    printf ', \033[1;31m%d failed\033[0m' "$failed"
fi
printf ' (out of %d tests)\n\n' "$total"

if [ "$failed" -gt 0 ]; then
    printf '\033[1;31mDEVICE MANAGEMENT TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mDEVICE MANAGEMENT TEST PASSED\033[0m\n'
    exit 0
fi
