#!/usr/bin/env bash
# =============================================================================
# 20-test-webhooks.sh — Webhooks API verification
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="dev-$(date +%s)"
TEST_PROJECT="xtest${RUN_ID##dev-}"
TEST_COLLECTION="webhook_test"

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
RULE_ID=""
API_TOKEN=""
READ_KEY=""
WRITE_KEY=""
MASTER_KEY=""
_RESP_FILE="/tmp/cenotoo_webhook_test_resp_$$.json"

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

header "Preflight & Setup"

if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    fail "CENOTOO_ADMIN_PASSWORD is not set"
    exit 1
fi

API_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$API_SVC" ]; then
    fail "Cannot find cenotoo-api Service in namespace $NAMESPACE"
    exit 1
fi

pkill -f "kubectl port-forward.*${API_PORT}:8000" 2>/dev/null || true
sleep 1

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

ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-cenotoo}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD}"

AUTH_HTTP=$(_api POST "${API_BASE}/token" -d "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}")
if [ "$AUTH_HTTP" = "200" ]; then
    API_TOKEN=$(jq -r '.access_token // ""' "$_RESP_FILE" 2>/dev/null || echo "")
else
    fail "API authentication failed (HTTP $AUTH_HTTP)"
    exit 1
fi

PROJ_HTTP=$(_api POST "${API_BASE}/projects" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"Webhook test\", \"tags\": []}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
else
    fail "Project creation failed"
    exit 1
fi

COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"Webhook test collection\", \"tags\": [], \"collection_schema\": {\"temp\": \"float\", \"room\": \"text\"}}")
if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
    COLLECTION_ID=$(curl -s "${API_BASE}/projects/${PROJECT_ID}/collections" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        | jq -r --arg name "$TEST_COLLECTION" '.items[] | select(.collection_name==$name) | .collection_id // ""' 2>/dev/null || echo "")
else
    fail "Collection creation failed"
    exit 1
fi

_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" -d '{"key_type": "read"}' >/dev/null
READ_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" -d '{"key_type": "write"}' >/dev/null
WRITE_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" -d '{"key_type": "master"}' >/dev/null
MASTER_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

header "TEST_01: Create Rule"

UNAUTH_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules" \
    -H "Content-Type: application/json" \
    -d '{"name": "High Temp", "field": "temp", "operator": "gt", "threshold": 30.0, "webhook_url": "http://localhost:19999"}')
if [ "$UNAUTH_HTTP" = "401" ] || [ "$UNAUTH_HTTP" = "403" ]; then
    pass "Unauthenticated request rejected (HTTP $UNAUTH_HTTP)"
else
    fail "Unauthenticated request accepted (HTTP $UNAUTH_HTTP)"
fi

WRITE_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules" \
    -H "X-API-Key: ${WRITE_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"name": "High Temp", "field": "temp", "operator": "gt", "threshold": 30.0, "webhook_url": "http://localhost:19999"}')
if [ "$WRITE_HTTP" = "403" ]; then
    pass "Write key rejected (HTTP 403)"
else
    fail "Write key accepted (HTTP $WRITE_HTTP)"
fi

MASTER_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules" \
    -H "X-API-Key: ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"name": "High Temp", "field": "temp", "operator": "gt", "threshold": 30.0, "webhook_url": "http://localhost:19999"}')
if [ "$MASTER_HTTP" = "200" ]; then
    pass "Master key accepted (HTTP 200)"
    RULE_ID=$(jq -r '.id // ""' "$_RESP_FILE")
else
    fail "Master key rejected (HTTP $MASTER_HTTP)"
fi

header "TEST_02: List & Get Rules"

LIST_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules" -H "X-API-Key: ${READ_KEY}")
if [ "$LIST_HTTP" = "200" ]; then
    COUNT=$(jq -r 'length' "$_RESP_FILE")
    if [ "$COUNT" -eq 1 ]; then
        pass "List rules returns 1 rule"
    else
        fail "List rules returns $COUNT rules (expected 1)"
    fi
else
    fail "List rules failed (HTTP $LIST_HTTP)"
fi

GET_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules/${RULE_ID}" -H "X-API-Key: ${READ_KEY}")
if [ "$GET_HTTP" = "200" ]; then
    NAME=$(jq -r '.name // ""' "$_RESP_FILE")
    if [ "$NAME" = "High Temp" ]; then
        pass "Get rule returns correct rule"
    else
        fail "Get rule returns wrong rule name: $NAME"
    fi
else
    fail "Get rule failed (HTTP $GET_HTTP)"
fi

header "TEST_03: Update Rule"

UPD_HTTP=$(_api PUT "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules/${RULE_ID}" \
    -H "X-API-Key: ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"threshold": 35.0, "enabled": false}')
if [ "$UPD_HTTP" = "200" ]; then
    THRESH=$(jq -r '.threshold // ""' "$_RESP_FILE")
    EN=$(jq -r '.enabled | tostring' "$_RESP_FILE")
    if [ "$THRESH" = "35.0" ] || [ "$THRESH" = "35" ]; then
        pass "Update rule threshold successful"
    else
        fail "Update rule threshold failed: $THRESH"
    fi
    if [ "$EN" = "false" ]; then
        pass "Update rule enabled toggle successful"
    else
        fail "Update rule enabled toggle failed: $EN"
    fi
else
    fail "Update rule failed (HTTP $UPD_HTTP)"
fi

_api PUT "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules/${RULE_ID}" \
    -H "X-API-Key: ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"enabled": true}' >/dev/null

header "TEST_04: Webhook Firing"

info "Ingesting a triggering record..."
_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/send_data" \
    -H "X-API-Key: ${WRITE_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"temp": 40.0, "room": "lab-01"}' >/dev/null

sleep 2

FIRE_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules/${RULE_ID}" -H "X-API-Key: ${READ_KEY}")
if [ "$FIRE_HTTP" = "200" ]; then
    LAST=$(jq -r '.last_fired_at // "null"' "$_RESP_FILE")
    if [ "$LAST" != "null" ]; then
        pass "last_fired_at is updated after ingest ($LAST)"
    else
        fail "last_fired_at is null after ingest"
    fi
else
    fail "Get rule failed (HTTP $FIRE_HTTP)"
fi

header "TEST_05: Delete Rule"

DEL_HTTP=$(_api DELETE "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules/${RULE_ID}" -H "X-API-Key: ${MASTER_KEY}")
if [ "$DEL_HTTP" = "200" ]; then
    pass "Delete rule returns 200"
    
    VERIFY_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/rules/${RULE_ID}" -H "X-API-Key: ${READ_KEY}")
    if [ "$VERIFY_HTTP" = "404" ]; then
        pass "Subsequent GET returns 404"
    else
        fail "Subsequent GET returned HTTP $VERIFY_HTTP (expected 404)"
    fi
else
    fail "Delete rule failed (HTTP $DEL_HTTP)"
fi

header "Summary"
rm -f "$_RESP_FILE"
total=$((passed + failed))
printf '\n  \033[1;32m%d passed\033[0m' "$passed"
if [ "$failed" -gt 0 ]; then
    printf ', \033[1;31m%d failed\033[0m' "$failed"
fi
printf ' (out of %d tests)\n\n' "$total"

if [ "$failed" -gt 0 ]; then
    exit 1
else
    exit 0
fi
