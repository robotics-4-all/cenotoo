#!/usr/bin/env bash
# =============================================================================
# 17-test-collection-metrics.sh — Collection Metrics API verification
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="dev-$(date +%s)"
TEST_PROJECT="xtest${RUN_ID##dev-}"
TEST_COLLECTION="metrics_test"

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
API_TOKEN=""
READ_KEY=""
WRITE_KEY=""
_RESP_FILE="/tmp/cenotoo_metrics_test_resp_$$.json"

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

ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-admin}"
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
    -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"Metrics test\", \"tags\": []}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
else
    fail "Project creation failed"
    exit 1
fi

COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"Metrics test collection\", \"tags\": [], \"collection_schema\": {\"temp\": \"float\", \"room\": \"text\"}}")
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

header "TEST_01: Metrics Endpoint"

UNAUTH_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/metrics")
if [ "$UNAUTH_HTTP" = "401" ] || [ "$UNAUTH_HTTP" = "403" ]; then
    pass "Unauthenticated request rejected (HTTP $UNAUTH_HTTP)"
else
    fail "Unauthenticated request accepted (HTTP $UNAUTH_HTTP)"
fi

METRICS_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/metrics" -H "X-API-Key: ${READ_KEY}")
if [ "$METRICS_HTTP" = "200" ]; then
    pass "Read key accepted (HTTP 200)"
    
    C_ID=$(jq -r '.collection_id // ""' "$_RESP_FILE")
    C_NAME=$(jq -r '.collection_name // ""' "$_RESP_FILE")
    TOPIC=$(jq -r '.kafka_topic // ""' "$_RESP_FILE")
    SCHEMA=$(jq -r '.schema_fields.temp // ""' "$_RESP_FILE")
    LIMIT=$(jq -r '.record_count_limit // ""' "$_RESP_FILE")
    
    if [ "$C_ID" = "$COLLECTION_ID" ] && [ "$C_NAME" = "$TEST_COLLECTION" ] && [ -n "$TOPIC" ] && [ "$SCHEMA" = "float" ]; then
        pass "Response contains correct collection_id, collection_name, kafka_topic, schema_fields"
    else
        fail "Response missing or incorrect fields: $(cat "$_RESP_FILE")"
    fi
    
    if [ "$LIMIT" = "100000" ]; then
        pass "record_count_limit is 100000"
    else
        fail "record_count_limit is $LIMIT (expected 100000)"
    fi
else
    fail "Metrics request failed (HTTP $METRICS_HTTP)"
fi

info "Ingesting a record..."
_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/store_data" \
    -H "X-API-Key: ${WRITE_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"temp": 22.5, "room": "lab-01"}' >/dev/null
sleep 2

METRICS_HTTP2=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/metrics" -H "X-API-Key: ${READ_KEY}")
if [ "$METRICS_HTTP2" = "200" ]; then
    COUNT=$(jq -r '.record_count // "null"' "$_RESP_FILE")
    LAST=$(jq -r '.last_ingested_at // "null"' "$_RESP_FILE")
    
    if [ "$COUNT" != "null" ] && [ "$COUNT" -gt 0 ]; then
        pass "record_count is non-null and > 0 after ingest ($COUNT)"
    else
        fail "record_count is $COUNT after ingest"
    fi
    
    if [ "$LAST" != "null" ]; then
        pass "last_ingested_at is non-null after ingest ($LAST)"
    else
        fail "last_ingested_at is null after ingest"
    fi
else
    fail "Metrics request 2 failed (HTTP $METRICS_HTTP2)"
fi

FAKE_ID="00000000-0000-0000-0000-000000000099"
NOT_FOUND_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${FAKE_ID}/metrics" -H "X-API-Key: ${READ_KEY}")
if [ "$NOT_FOUND_HTTP" = "404" ]; then
    pass "Non-existent collection returns 404"
else
    fail "Non-existent collection returned HTTP $NOT_FOUND_HTTP (expected 404)"
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
