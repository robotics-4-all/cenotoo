#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-cenotoo}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD:?CENOTOO_ADMIN_PASSWORD is required}"

API_NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
API_PORT=$(kubectl get svc -n "${NAMESPACE}" "${RELEASE}-api" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
BASE_URL="http://${API_NODE_IP}:${API_PORT}/api/v1"

RUN_ID=$(date +%s)
TEST_PROJECT="ssetest${RUN_ID}"
TEST_COLLECTION="readings"

PASS=0
FAIL=0
ERRORS=()

pass_test() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail_test() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

api() {
    local method="$1" path="$2"; shift 2
    curl -s -X "$method" "${BASE_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@"
}

api_status() {
    local method="$1" path="$2"; shift 2
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "${BASE_URL}${path}" \
        -H "Content-Type: application/json" \
        "$@"
}

echo "========================================"
echo " Cenotoo SSE Streaming Tests"
echo " API: ${BASE_URL}"
echo "========================================"

# --- Auth ---
echo ""
echo "[Setup] Authenticating..."
TOKEN=$(curl -s -X POST "${BASE_URL}/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}" \
    | jq -r '.access_token // ""')
[[ -z "$TOKEN" ]] && { echo "FATAL: auth failed (check CENOTOO_ADMIN_USERNAME / CENOTOO_ADMIN_PASSWORD)"; exit 1; }
AUTH=(-H "Authorization: Bearer ${TOKEN}")

# --- Project & Collection setup ---
echo "[Setup] Creating project..."
PROJECT_ID=$(api POST /projects "${AUTH[@]}" \
    -d "{\"project_name\":\"${TEST_PROJECT}\",\"description\":\"SSE test\",\"tags\":[]}" \
    | jq -r '.id.project_id // .project_id // .id // ""')
[[ -z "$PROJECT_ID" ]] && { echo "FATAL: project creation failed"; exit 1; }

echo "[Setup] Creating collection..."
api POST "/projects/${PROJECT_ID}/collections" "${AUTH[@]}" \
    -d "{\"name\":\"${TEST_COLLECTION}\",\"description\":\"SSE test collection\",\"tags\":[],\"collection_schema\":{\"sensor_id\":\"text\",\"value\":\"float\"}}" > /dev/null
COLL_ID=$(api GET "/projects/${PROJECT_ID}/collections" "${AUTH[@]}" \
    | jq -r --arg name "$TEST_COLLECTION" '.items[] | select(.collection_name==$name) | .collection_id // ""')
[[ -z "$COLL_ID" ]] && { echo "FATAL: collection creation failed"; exit 1; }

echo "[Setup] Creating API keys..."
READ_KEY=$(api POST "/projects/${PROJECT_ID}/keys" "${AUTH[@]}" \
    -d '{"key_type":"read"}' | jq -r '.api_key // ""')
WRITE_KEY=$(api POST "/projects/${PROJECT_ID}/keys" "${AUTH[@]}" \
    -d '{"key_type":"write"}' | jq -r '.api_key // ""')
STREAM_PATH="/projects/${PROJECT_ID}/collections/${COLL_ID}/stream"

echo ""
echo "--- Test Group: Authentication ---"

# TEST_01: Unauthenticated request must be rejected
STATUS=$(api_status GET "${STREAM_PATH}")
if [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
    pass_test "TEST_01: Unauthenticated stream request rejected (${STATUS})"
else
    fail_test "TEST_01: Expected 401/403, got ${STATUS}"
fi

# TEST_02: Read key is accepted (200 — streaming response)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: ${READ_KEY}" \
    --max-time 2 \
    "${BASE_URL}${STREAM_PATH}" 2>/dev/null || true)
if [[ "$STATUS" == "200" ]]; then
    pass_test "TEST_02: Read API key accepted for SSE stream (200)"
else
    fail_test "TEST_02: Expected 200 with read key, got ${STATUS}"
fi

# TEST_03: Write key is accepted
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: ${WRITE_KEY}" \
    --max-time 2 \
    "${BASE_URL}${STREAM_PATH}" 2>/dev/null || true)
if [[ "$STATUS" == "200" ]]; then
    pass_test "TEST_03: Write API key accepted for SSE stream (200)"
else
    fail_test "TEST_03: Expected 200 with write key, got ${STATUS}"
fi

# TEST_04: JWT token is accepted
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    --max-time 2 \
    "${BASE_URL}${STREAM_PATH}" 2>/dev/null || true)
if [[ "$STATUS" == "200" ]]; then
    pass_test "TEST_04: JWT token accepted for SSE stream (200)"
else
    fail_test "TEST_04: Expected 200 with JWT, got ${STATUS}"
fi

echo ""
echo "--- Test Group: Content-Type ---"

# TEST_05: Response Content-Type is text/event-stream
CT=$(curl -s -o /dev/null -w "%{content_type}" \
    -H "X-API-Key: ${READ_KEY}" \
    --max-time 2 \
    "${BASE_URL}${STREAM_PATH}" 2>/dev/null || true)
if echo "$CT" | grep -q "text/event-stream"; then
    pass_test "TEST_05: Response Content-Type is text/event-stream (${CT})"
else
    fail_test "TEST_05: Expected text/event-stream, got '${CT}'"
fi

# TEST_06: X-Accel-Buffering header is set to no
XAB=$(curl -s -D - -o /dev/null \
    -H "X-API-Key: ${READ_KEY}" \
    --max-time 2 \
    "${BASE_URL}${STREAM_PATH}" 2>/dev/null \
    | grep -i "x-accel-buffering" | tr -d '\r' || true)
if echo "$XAB" | grep -qi "no"; then
    pass_test "TEST_06: X-Accel-Buffering: no header present"
else
    fail_test "TEST_06: X-Accel-Buffering header missing or incorrect (got '${XAB}')"
fi

echo ""
echo "--- Test Group: Live Data Delivery ---"

SSE_TMP=$(mktemp)

# TEST_07: SSE stream delivers data sent after connection opens
(
    curl -s \
        -H "X-API-Key: ${READ_KEY}" \
        --max-time 8 \
        "${BASE_URL}${STREAM_PATH}" > "${SSE_TMP}" 2>/dev/null || true
) &
SSE_PID=$!

sleep 1

api POST "/projects/${PROJECT_ID}/collections/${COLL_ID}/send_data" \
    -H "X-API-Key: ${WRITE_KEY}" \
    -d '{"sensor_id":"sse-sensor-01","value":42.5}' > /dev/null

sleep 1

api POST "/projects/${PROJECT_ID}/collections/${COLL_ID}/send_data" \
    -H "X-API-Key: ${WRITE_KEY}" \
    -d '{"sensor_id":"sse-sensor-02","value":99.9}' > /dev/null

wait $SSE_PID 2>/dev/null || true

if grep -q '"sensor_id"' "${SSE_TMP}" 2>/dev/null; then
    pass_test "TEST_07: SSE stream delivered live data messages"
else
    fail_test "TEST_07: No data received over SSE stream"
fi

# TEST_08: SSE events are prefixed with 'data: '
if grep -q '^data: ' "${SSE_TMP}" 2>/dev/null; then
    pass_test "TEST_08: SSE events correctly formatted with 'data: ' prefix"
else
    fail_test "TEST_08: SSE events missing 'data: ' prefix"
fi

# TEST_09: SSE event payloads are valid JSON
INVALID_JSON=0
while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
        payload="${line#data: }"
        if ! echo "$payload" | jq . > /dev/null 2>&1; then
            INVALID_JSON=$((INVALID_JSON + 1))
        fi
    fi
done < "${SSE_TMP}"

if [[ $INVALID_JSON -eq 0 ]]; then
    pass_test "TEST_09: All SSE event payloads are valid JSON"
else
    fail_test "TEST_09: ${INVALID_JSON} SSE events contained invalid JSON"
fi

# TEST_10: Multiple messages received
MSG_COUNT=$(grep -c '^data: ' "${SSE_TMP}" 2>/dev/null || echo "0")
if [[ $MSG_COUNT -ge 2 ]]; then
    pass_test "TEST_10: Received ${MSG_COUNT} SSE messages (≥2 expected)"
else
    fail_test "TEST_10: Expected ≥2 SSE messages, got ${MSG_COUNT}"
fi

rm -f "${SSE_TMP}"

echo ""
echo "--- Test Group: Non-existent Collection ---"

FAKE_ID="00000000-0000-0000-0000-000000000000"

# TEST_11: Non-existent collection returns 404
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    --max-time 2 \
    "${BASE_URL}/projects/${PROJECT_ID}/collections/${FAKE_ID}/stream" 2>/dev/null || true)
if [[ "$STATUS" == "404" ]]; then
    pass_test "TEST_11: Non-existent collection returns 404"
else
    fail_test "TEST_11: Expected 404 for missing collection, got ${STATUS}"
fi

# TEST_12: Non-existent project returns 404
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    --max-time 2 \
    "${BASE_URL}/projects/${FAKE_ID}/collections/${FAKE_ID}/stream" 2>/dev/null || true)
if [[ "$STATUS" == "404" ]]; then
    pass_test "TEST_12: Non-existent project returns 404"
else
    fail_test "TEST_12: Expected 404 for missing project, got ${STATUS}"
fi

# --- Cleanup ---
echo ""
echo "[Cleanup] Removing test project..."
api DELETE "/projects/${PROJECT_ID}/collections/${COLL_ID}" "${AUTH[@]}" > /dev/null || true
api DELETE "/projects/${PROJECT_ID}" "${AUTH[@]}" > /dev/null || true

echo ""
echo "========================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo " Failed tests:"
    for e in "${ERRORS[@]}"; do echo "   - $e"; done
fi
echo ""
[[ $FAIL -eq 0 ]]
