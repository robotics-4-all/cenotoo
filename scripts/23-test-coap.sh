#!/usr/bin/env bash
# =============================================================================
# 23-test-coap.sh — End-to-end CoAP pipeline verification for Cenotoo
#
# Tests the full CoAP ingestion stack on a running k3s cluster:
#   1. Pod/deployment health (coap-bridge)
#   2. HTTP health endpoint (/health on :8080)
#   3. Auth rejection — missing ?key= parameter
#   4. Auth rejection — invalid API key
#   5. URI validation — wrong segment count (2-segment and 4-segment paths)
#   6. Payload size enforcement — payload > MAX_PAYLOAD_BYTES (1024)
#   7. E2E pipeline: CoAP POST → coap-bridge → Kafka topic
#   8. Bridge log health
#
# CoAP requests are sent from inside the coap-bridge pod using aiocoap (already
# installed in the container image). kubectl exec -i feeds a Python script via
# stdin — no external coap-client tool required.
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username  (default: cenotoo)
#   CENOTOO_ADMIN_PASSWORD   API admin password  (required — no default)
#
# Prerequisites:
#   - jq, curl, kubectl
#   - Cenotoo deployed (07), CoAP bridge deployed (22), API deployed (08)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/23-test-coap.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="coap-$(date +%s)"
TEST_PROJECT="coaptest${RUN_ID##coap-}"
TEST_COLLECTION="sensors"

API_PORT=8000
API_BASE="http://localhost:${API_PORT}/api/v1"

passed=0
failed=0

pass()   { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()   { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()   { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

PF_API_PID=""
PROJECT_ID=""
API_TOKEN=""
COAP_POD=""

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
    rm -f "/tmp/cenotoo_coap_test_resp_$$.json" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# coap_post <coap-uri> <json-payload-string>
#
# Sends a CoAP POST from inside the coap-bridge pod using aiocoap.
# Feeds a Python script via stdin (kubectl exec -i) — no external tool needed.
# Prints the CoAP response code, e.g. "2.04 Changed" or "4.01 Unauthorized".
#
# The heredoc uses an unquoted delimiter so bash expands $coap_uri and $payload.
# JSON payloads are embedded inside Python b'...' — safe as long as they contain
# no single quotes (all our test payloads use only double-quoted JSON strings).
# ---------------------------------------------------------------------------
coap_post() {
    local coap_uri="$1"
    local payload="${2:-{}}"
    kubectl exec -n "$NAMESPACE" -i "$COAP_POD" -- python3 << PYEOF 2>/dev/null
import asyncio, aiocoap
async def main():
    ctx = await aiocoap.Context.create_client_context()
    req = aiocoap.Message(code=aiocoap.POST, uri="$coap_uri", payload=b'$payload')
    resp = await ctx.request(req).response
    await ctx.shutdown()
    print(resp.code)
asyncio.run(main())
PYEOF
}

# ---------------------------------------------------------------------------
# coap_post_bytes <coap-uri> <python-bytes-expr>
#
# Like coap_post but lets you specify the payload as a raw Python bytes
# expression, e.g. b"x" * 1025, for testing oversized payload rejection.
# ---------------------------------------------------------------------------
coap_post_bytes() {
    local coap_uri="$1"
    local payload_expr="$2"
    kubectl exec -n "$NAMESPACE" -i "$COAP_POD" -- python3 << PYEOF 2>/dev/null
import asyncio, aiocoap
async def main():
    ctx = await aiocoap.Context.create_client_context()
    req = aiocoap.Message(code=aiocoap.POST, uri="$coap_uri", payload=$payload_expr)
    resp = await ctx.request(req).response
    await ctx.shutdown()
    print(resp.code)
asyncio.run(main())
PYEOF
}

# ---------------------------------------------------------------------------
printf '\n\033[1;36m\033[1m'
printf '  ╔══════════════════════════════════════════════╗\n'
printf '  ║    Cenotoo CoAP Bridge — Integration Tests  ║\n'
printf '  ╚══════════════════════════════════════════════╝\n'
printf '\033[0m\n'
# ---------------------------------------------------------------------------

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
    printf '\n\033[1;31mCannot run CoAP tests without the cenotoo namespace. Exiting.\033[0m\n'
    exit 1
fi
pass "Namespace $NAMESPACE exists"

# ---------------------------------------------------------------------------
header "Pod Health"
# ---------------------------------------------------------------------------
COAP_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=coap-bridge,app.kubernetes.io/part-of=${RELEASE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$COAP_POD" ]; then
    pass "coap-bridge pod running: $COAP_POD"
else
    fail "No running coap-bridge pod found (label: component=coap-bridge)"
    printf '\n\033[1;31mCannot run CoAP tests without the bridge pod. Exiting.\033[0m\n'
    exit 1
fi

BRIDGE_AVAILABLE=$(kubectl get deployment "cenotoo-coap-bridge" -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
BRIDGE_DESIRED=$(kubectl get deployment "cenotoo-coap-bridge" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
if [ "${BRIDGE_AVAILABLE:-0}" = "$BRIDGE_DESIRED" ] && [ "$BRIDGE_DESIRED" != "0" ]; then
    pass "coap-bridge deployment: ${BRIDGE_AVAILABLE}/${BRIDGE_DESIRED} replicas available"
else
    fail "coap-bridge deployment: ${BRIDGE_AVAILABLE:-0}/${BRIDGE_DESIRED} replicas available"
fi

BRIDGE_RESTARTS=$(kubectl get pod "$COAP_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "${BRIDGE_RESTARTS:-0}" -lt 10 ]; then
    pass "coap-bridge restart count: ${BRIDGE_RESTARTS:-0} (healthy)"
else
    fail "coap-bridge restart count: $BRIDGE_RESTARTS (possible crash loop)"
fi

# ---------------------------------------------------------------------------
header "HTTP Health Endpoint"
# ---------------------------------------------------------------------------
HEALTH_STATUS=$(kubectl exec -n "$NAMESPACE" "$COAP_POD" -- \
    python3 -c "import urllib.request; r = urllib.request.urlopen('http://localhost:8080/health'); print(r.status)" \
    2>/dev/null || echo "")

if [ "${HEALTH_STATUS:-}" = "200" ]; then
    pass "HTTP /health returned 200"
else
    fail "HTTP /health did not return 200 (got: '${HEALTH_STATUS:-error}')"
fi

# ---------------------------------------------------------------------------
header "Port-Forward Setup"
# ---------------------------------------------------------------------------
API_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$API_SVC" ]; then
    fail "Cannot find cenotoo-api Service in namespace $NAMESPACE"
    printf '\n\033[1;31mCannot run CoAP tests without the API. Exiting.\033[0m\n'
    exit 1
fi

info "Port-forwarding $API_SVC → localhost:${API_PORT} ..."
kubectl port-forward "svc/${API_SVC}" "${API_PORT}:8000" -n "$NAMESPACE" &>/dev/null &
PF_API_PID=$!
sleep 3

if kill -0 "$PF_API_PID" 2>/dev/null; then
    pass "API port-forward active (pid $PF_API_PID)"
else
    fail "API port-forward failed"
fi

# ---------------------------------------------------------------------------
header "API Setup"
# ---------------------------------------------------------------------------
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-cenotoo}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD}"

_RESP_FILE="/tmp/cenotoo_coap_test_resp_$$.json"
_api() {
    local method="$1" url="$2"; shift 2
    local http
    http=$(curl -s -o "$_RESP_FILE" -w "%{http_code}" -X "$method" "$url" "$@" 2>/dev/null || echo "000")
    echo "$http"
}

info "Authenticating as $ADMIN_USERNAME ..."
AUTH_HTTP=$(_api POST "${API_BASE}/token" \
    -d "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}")
if [ "$AUTH_HTTP" = "200" ]; then
    API_TOKEN=$(jq -r '.access_token // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "null" ]; then
        pass "API authentication successful"
    else
        fail "API auth: got 200 but no access_token in response"
        API_TOKEN=""
    fi
else
    fail "API authentication failed (HTTP $AUTH_HTTP) — check CENOTOO_ADMIN_USERNAME ($ADMIN_USERNAME) and CENOTOO_ADMIN_PASSWORD"
fi

ORG_NAME=""
if [ -n "$API_TOKEN" ]; then
    ORG_HTTP=$(_api GET "${API_BASE}/organization" \
        -H "Authorization: Bearer ${API_TOKEN}")
    if [ "$ORG_HTTP" = "200" ]; then
        ORG_NAME=$(jq -r '.organization_name // .name // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ -n "$ORG_NAME" ]; then
            pass "Organization name: $ORG_NAME"
        else
            fail "Cannot parse organization name from API response"
        fi
    else
        fail "Organization fetch failed (HTTP $ORG_HTTP)"
    fi
fi

if [ -n "$API_TOKEN" ]; then
    info "Creating test project: $TEST_PROJECT ..."
    PROJ_HTTP=$(_api POST "${API_BASE}/projects" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"CoAP integration test\", \"tags\": [\"test\"]}")
    if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
        PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
            pass "Test project created: $PROJECT_ID"
        else
            fail "Project created (HTTP $PROJ_HTTP) but no ID in response: $(cat "$_RESP_FILE")"
        fi
    else
        fail "Project creation failed (HTTP $PROJ_HTTP): $(cat "$_RESP_FILE")"
    fi
fi

if [ -n "${PROJECT_ID:-}" ]; then
    info "Creating test collection: $TEST_COLLECTION ..."
    COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"CoAP test\", \"tags\": [\"test\"], \"collection_schema\": {\"value\": \"float\", \"device_id\": \"text\"}}")
    if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
        pass "Test collection created (HTTP $COLL_HTTP)"
    else
        fail "Collection creation failed (HTTP $COLL_HTTP): $(cat "$_RESP_FILE")"
    fi
fi

DEVICE_KEY=""
if [ -n "${PROJECT_ID:-}" ]; then
    info "Creating write API key for project $PROJECT_ID ..."
    KEY_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"key_type": "write"}')
    if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
        DEVICE_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ -n "$DEVICE_KEY" ] && [ "$DEVICE_KEY" != "null" ]; then
            pass "Write API key created (${#DEVICE_KEY} chars)"
        else
            fail "Key created (HTTP $KEY_HTTP) but no api_key in response"
        fi
    else
        fail "API key creation failed (HTTP $KEY_HTTP): $(cat "$_RESP_FILE")"
    fi
fi
rm -f "$_RESP_FILE"

COAP_BASE="coap://localhost:5683"
COAP_PATH="${ORG_NAME:-testorg}/${TEST_PROJECT}/${TEST_COLLECTION}"

# ---------------------------------------------------------------------------
header "Test 1: Missing API Key → 4.01 Unauthorized"
# ---------------------------------------------------------------------------
if [ -n "$COAP_POD" ] && [ -n "${ORG_NAME:-}" ]; then
    info "POST /$COAP_PATH (no ?key=) ..."
    RESP=$(coap_post "${COAP_BASE}/${COAP_PATH}" '{"value": 1.0}')
    if echo "$RESP" | grep -q "4.01"; then
        pass "Missing ?key=: rejected with 4.01 Unauthorized (got: $RESP)"
    else
        fail "Missing ?key=: expected 4.01 Unauthorized, got: '${RESP:-error}'"
    fi
else
    info "Skipping (no running pod or org name)"
fi

# ---------------------------------------------------------------------------
header "Test 2: Invalid API Key → 4.01 Unauthorized"
# ---------------------------------------------------------------------------
if [ -n "$COAP_POD" ] && [ -n "${ORG_NAME:-}" ]; then
    FAKE_KEY="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    info "POST /$COAP_PATH?key=$FAKE_KEY ..."
    RESP=$(coap_post "${COAP_BASE}/${COAP_PATH}?key=${FAKE_KEY}" '{"value": 1.0}')
    if echo "$RESP" | grep -q "4.01"; then
        pass "Invalid key: rejected with 4.01 Unauthorized (got: $RESP)"
    else
        fail "Invalid key: expected 4.01 Unauthorized, got: '${RESP:-error}'"
    fi
else
    info "Skipping (no running pod or org name)"
fi

# ---------------------------------------------------------------------------
header "Test 3: Wrong URI Segment Count → 4.00 Bad Request"
# ---------------------------------------------------------------------------
if [ -n "$COAP_POD" ] && [ -n "${ORG_NAME:-}" ] && [ -n "${DEVICE_KEY:-}" ]; then
    info "POST /${ORG_NAME}/${TEST_COLLECTION} (2 segments — missing project) ..."
    RESP=$(coap_post "${COAP_BASE}/${ORG_NAME}/${TEST_COLLECTION}?key=${DEVICE_KEY}" '{"value": 1.0}')
    if echo "$RESP" | grep -q "4.00"; then
        pass "2-segment URI: rejected with 4.00 Bad Request (got: $RESP)"
    else
        fail "2-segment URI: expected 4.00 Bad Request, got: '${RESP:-error}'"
    fi

    info "POST /${ORG_NAME}/${TEST_PROJECT}/${TEST_COLLECTION}/extra (4 segments) ..."
    RESP=$(coap_post "${COAP_BASE}/${ORG_NAME}/${TEST_PROJECT}/${TEST_COLLECTION}/extra?key=${DEVICE_KEY}" '{"value": 1.0}')
    if echo "$RESP" | grep -q "4.00"; then
        pass "4-segment URI: rejected with 4.00 Bad Request (got: $RESP)"
    else
        fail "4-segment URI: expected 4.00 Bad Request, got: '${RESP:-error}'"
    fi
else
    info "Skipping (no running pod, org name, or device key)"
fi

# ---------------------------------------------------------------------------
header "Test 4: Oversized Payload → 4.13 Request Entity Too Large"
# ---------------------------------------------------------------------------
if [ -n "$COAP_POD" ] && [ -n "${ORG_NAME:-}" ] && [ -n "${DEVICE_KEY:-}" ]; then
    info "POST with 1025-byte payload (MAX_PAYLOAD_BYTES=1024) ..."
    RESP=$(coap_post_bytes "${COAP_BASE}/${COAP_PATH}?key=${DEVICE_KEY}" 'b"x" * 1025')
    if echo "$RESP" | grep -q "4.13"; then
        pass "Oversized payload: rejected with 4.13 Request Entity Too Large (got: $RESP)"
    else
        fail "Oversized payload: expected 4.13 Request Entity Too Large, got: '${RESP:-error}'"
    fi
else
    info "Skipping (no running pod, org name, or device key)"
fi

# ---------------------------------------------------------------------------
header "Test 5: E2E Pipeline (CoAP POST → coap-bridge → Kafka)"
# ---------------------------------------------------------------------------
if [ -n "$COAP_POD" ] && [ -n "${ORG_NAME:-}" ] && [ -n "${DEVICE_KEY:-}" ]; then
    KAFKA_TOPIC="${ORG_NAME}.${TEST_PROJECT}.${TEST_COLLECTION}"
    E2E_DEVICE_ID="${RUN_ID}-e2e"

    KAFKA_POD=$(kubectl get pod -n "$NAMESPACE" \
        -l "strimzi.io/cluster=${RELEASE}-kafka,strimzi.io/kind=Kafka" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$KAFKA_POD" ]; then
        fail "E2E: No running Kafka broker pod found"
    else
        info "Sending E2E CoAP message (device_id=$E2E_DEVICE_ID) ..."
        RESP=$(coap_post \
            "${COAP_BASE}/${COAP_PATH}?key=${DEVICE_KEY}" \
            "{\"value\": 99.9, \"device_id\": \"${E2E_DEVICE_ID}\"}")
        if echo "$RESP" | grep -q "2.04"; then
            pass "E2E: CoAP POST accepted by bridge (got: $RESP)"
        else
            fail "E2E: CoAP POST failed — expected 2.04 Changed, got: '${RESP:-error}'"
            KAFKA_POD=""
        fi
    fi

    if [ -n "${KAFKA_POD:-}" ]; then
        info "Consuming from Kafka topic $KAFKA_TOPIC (15s timeout) ..."
        CONSUMED=$(kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
            /opt/kafka/bin/kafka-console-consumer.sh \
            --bootstrap-server localhost:9092 \
            --topic "$KAFKA_TOPIC" \
            --from-beginning \
            --timeout-ms 15000 \
            2>/dev/null || echo "")

        if echo "$CONSUMED" | grep -q "$E2E_DEVICE_ID"; then
            pass "E2E pipeline: CoAP → coap-bridge → Kafka ✓ (message on topic $KAFKA_TOPIC)"
        else
            fail "E2E pipeline: message not found on Kafka topic $KAFKA_TOPIC after 15s"
            info "Debug: kubectl -n $NAMESPACE logs pod/$COAP_POD --tail=50"
        fi
    fi
else
    info "Skipping E2E pipeline test (missing pod, org name, or device key)"
fi

# ---------------------------------------------------------------------------
header "Test 6: Bridge Log Health"
# ---------------------------------------------------------------------------
BRIDGE_LOGS=$(kubectl logs -n "$NAMESPACE" "pod/$COAP_POD" --tail=50 2>/dev/null || echo "")
BRIDGE_ERRORS=$(printf '%s' "$BRIDGE_LOGS" | grep -cE '\[(ERROR|CRITICAL)\]|Exception|Traceback|ConnectionError' || true)
BRIDGE_STARTED=$(printf '%s' "$BRIDGE_LOGS" | grep -ci 'CoAP server listening\|HTTP health server started' || true)

if [ "${BRIDGE_ERRORS:-0}" -eq 0 ]; then
    pass "coap-bridge logs: no errors in last 50 lines"
else
    fail "coap-bridge logs: $BRIDGE_ERRORS error(s) found in last 50 lines"
fi

if [ "${BRIDGE_STARTED:-0}" -gt 0 ]; then
    pass "coap-bridge logs: startup messages found"
else
    info "coap-bridge: no startup messages in recent 50 lines (may be old startup)"
fi

# ---------------------------------------------------------------------------
header "Summary"
# ---------------------------------------------------------------------------
total=$((passed + failed))
printf '\n  \033[1;32m%d passed\033[0m' "$passed"
if [ "$failed" -gt 0 ]; then
    printf ', \033[1;31m%d failed\033[0m' "$failed"
fi
printf ' (out of %d tests)\n\n' "$total"

if [ "$failed" -gt 0 ]; then
    printf '\033[1;31mCoAP TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mCoAP TEST PASSED\033[0m\n'
    exit 0
fi
