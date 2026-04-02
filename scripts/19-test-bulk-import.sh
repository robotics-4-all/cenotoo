#!/usr/bin/env bash
# =============================================================================
# 19-test-bulk-import.sh — Bulk Import API verification
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="dev-$(date +%s)"
TEST_PROJECT="xtest${RUN_ID##dev-}"
TEST_COLLECTION="import_test"

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
_RESP_FILE="/tmp/cenotoo_import_test_resp_$$.json"
_CSV_FILE="/tmp/cenotoo_import_test_$$.csv"
_JSON_FILE="/tmp/cenotoo_import_test_$$.json"

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
    rm -f "$_RESP_FILE" "$_CSV_FILE" "$_JSON_FILE" 2>/dev/null || true
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
    -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"Import test\", \"tags\": []}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
else
    fail "Project creation failed"
    exit 1
fi

COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"Import test collection\", \"tags\": [], \"collection_schema\": {\"temp\": \"float\", \"room\": \"text\"}}")
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

header "TEST_01: Import Endpoint"

UNAUTH_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/import" -F "file=@/dev/null")
if [ "$UNAUTH_HTTP" = "401" ] || [ "$UNAUTH_HTTP" = "403" ]; then
    pass "Unauthenticated request rejected (HTTP $UNAUTH_HTTP)"
else
    fail "Unauthenticated request accepted (HTTP $UNAUTH_HTTP)"
fi

cat <<EOF > "$_CSV_FILE"
temp,room
22.5,lab-01
23.0,lab-02
EOF

CSV_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/import" -H "X-API-Key: ${WRITE_KEY}" -F "file=@${_CSV_FILE}")
if [ "$CSV_HTTP" = "200" ]; then
    IMPORTED=$(jq -r '.imported // 0' "$_RESP_FILE")
    if [ "$IMPORTED" -eq 2 ]; then
        pass "CSV import successful (imported $IMPORTED)"
    else
        fail "CSV import returned imported=$IMPORTED (expected 2)"
    fi
else
    fail "CSV import failed (HTTP $CSV_HTTP)"
fi

cat <<EOF > "$_JSON_FILE"
[
  {"temp": 21.5, "room": "lab-03"},
  {"temp": 24.0, "room": "lab-04"}
]
EOF

JSON_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/import" -H "X-API-Key: ${WRITE_KEY}" -F "file=@${_JSON_FILE}")
if [ "$JSON_HTTP" = "200" ]; then
    IMPORTED=$(jq -r '.imported // 0' "$_RESP_FILE")
    if [ "$IMPORTED" -eq 2 ]; then
        pass "JSON import successful (imported $IMPORTED)"
    else
        fail "JSON import returned imported=$IMPORTED (expected 2)"
    fi
else
    fail "JSON import failed (HTTP $JSON_HTTP)"
fi

cat <<EOF > "$_CSV_FILE"
temp,room
22.5,lab-05
invalid,lab-06
23.0,lab-07
EOF

MIXED_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/import" -H "X-API-Key: ${WRITE_KEY}" -F "file=@${_CSV_FILE}")
if [ "$MIXED_HTTP" = "200" ]; then
    IMPORTED=$(jq -r '.imported // 0' "$_RESP_FILE")
    SKIPPED=$(jq -r '.skipped // 0' "$_RESP_FILE")
    if [ "$IMPORTED" -eq 2 ] && [ "$SKIPPED" -eq 1 ]; then
        pass "Mixed valid/invalid CSV import successful (imported $IMPORTED, skipped $SKIPPED)"
    else
        fail "Mixed CSV import returned imported=$IMPORTED, skipped=$SKIPPED (expected 2, 1)"
    fi
else
    fail "Mixed CSV import failed (HTTP $MIXED_HTTP)"
fi

sleep 2
GET_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/get_data" -H "X-API-Key: ${READ_KEY}")
if [ "$GET_HTTP" = "200" ]; then
    TOTAL=$(jq -r '.total_count // 0' "$_RESP_FILE")
    if [ "$TOTAL" -ge 6 ]; then
        pass "Imported records appear in get_data (total $TOTAL)"
    else
        fail "Imported records missing in get_data (total $TOTAL, expected >= 6)"
    fi
else
    fail "get_data failed (HTTP $GET_HTTP)"
fi

FAKE_ID="00000000-0000-0000-0000-000000000099"
NOT_FOUND_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${FAKE_ID}/import" -H "X-API-Key: ${WRITE_KEY}" -F "file=@${_CSV_FILE}")
if [ "$NOT_FOUND_HTTP" = "404" ]; then
    pass "Non-existent collection returns 404"
else
    fail "Non-existent collection returned HTTP $NOT_FOUND_HTTP (expected 404)"
fi

header "Summary"
rm -f "$_RESP_FILE" "$_CSV_FILE" "$_JSON_FILE"
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
