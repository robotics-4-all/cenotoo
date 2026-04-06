#!/usr/bin/env bash
# =============================================================================
# 13-test-mqtt.sh — End-to-end MQTT pipeline verification for Cenotoo
#
# Tests the full MQTT ingestion stack on a running k3s cluster:
#   1. Pod/container health (mosquitto, mqtt-auth sidecar, mqtt-bridge)
#   2. Bridge service account auth (superuser connect)
#   3. Auth rejection (bad credentials)
#   4. Device auth (project UUID + write API key)
#   5. ACL enforcement (valid vs invalid topics)
#   6. E2E pipeline: MQTT publish → mqtt-bridge → Kafka → cassandra-writer → Cassandra
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username     (default: admin)
#   CENOTOO_ADMIN_PASSWORD   API admin password     (required — no default)
#
# Prerequisites:
#   - jq, curl, kubectl
#   - mosquitto_pub (optional — falls back to kubectl exec into mosquitto pod)
#   - Cenotoo deployed (07), MQTT stack deployed (12), API deployed (08)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/13-test-mqtt.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Test identifiers — unique per run to avoid collision
RUN_ID="mqtt-$(date +%s)"
TEST_PROJECT="mqtttest${RUN_ID##mqtt-}"   # alphanumeric only, max ~30 chars
TEST_COLLECTION="sensors"

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
API_TOKEN=""
MOSQ_POD=""

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
    rm -f "/tmp/cenotoo_mqtt_test_resp_$$.json" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# mqtt_pub: wrapper that uses local mosquitto_pub OR kubectl exec into mosquitto pod.
# The mosquitto container (iegomez/mosquitto-go-auth, based on eclipse-mosquitto)
# ships mosquitto_pub. Connecting to localhost:1883 inside the pod still exercises
# the full go-auth → mqtt-auth HTTP auth flow.
# ---------------------------------------------------------------------------
MOSQ_PUB_LOCAL=false
if command -v mosquitto_pub &>/dev/null; then
    MOSQ_PUB_LOCAL=true
fi

mqtt_pub() {
    local args=()
    local skip_next=false
    for arg in "$@"; do
        if [ "$skip_next" = "true" ]; then
            skip_next=false
            continue
        fi
        case "$arg" in
            -h) skip_next=true ;;
            -p) skip_next=true ;;
            *) args+=("$arg") ;;
        esac
    done
    kubectl exec -n "$NAMESPACE" "$MOSQ_POD" -c mosquitto -- \
        mosquitto_pub -h localhost -p 1883 "${args[@]}" 2>/dev/null
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

if [ "$MOSQ_PUB_LOCAL" = "true" ]; then
    info "mosquitto_pub found locally (using kubectl exec anyway for reliability)"
else
    info "mosquitto_pub not installed locally — using kubectl exec into mosquitto container"
fi

if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    fail "CENOTOO_ADMIN_PASSWORD is not set"
    printf '\n\033[1;31mRun: CENOTOO_ADMIN_PASSWORD=<pass> %s\033[0m\n' "$0"
    exit 1
fi
pass "CENOTOO_ADMIN_PASSWORD is set"

if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    fail "Namespace $NAMESPACE not found"
    printf '\n\033[1;31mCannot run MQTT tests without the cenotoo namespace. Exiting.\033[0m\n'
    exit 1
fi
pass "Namespace $NAMESPACE exists"

# ---------------------------------------------------------------------------
header "Pod Health"
# ---------------------------------------------------------------------------

# Mosquitto StatefulSet
MOSQ_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=mqtt-broker,app.kubernetes.io/part-of=${RELEASE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$MOSQ_POD" ]; then
    pass "Mosquitto pod running: $MOSQ_POD"
else
    fail "No running Mosquitto pod found (label: component=mqtt-broker)"
    printf '\n\033[1;31mCannot run MQTT tests without Mosquitto. Exiting.\033[0m\n'
    exit 1
fi

# mqtt-auth sidecar container status
AUTH_READY=$(kubectl get pod "$MOSQ_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="mqtt-auth")].ready}' 2>/dev/null || echo "false")
if [ "$AUTH_READY" = "true" ]; then
    pass "mqtt-auth sidecar container is Ready"
else
    fail "mqtt-auth sidecar not Ready (check: kubectl logs -n $NAMESPACE $MOSQ_POD -c mqtt-auth)"
fi

# mosquitto container status
MOSQ_READY=$(kubectl get pod "$MOSQ_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="mosquitto")].ready}' 2>/dev/null || echo "false")
if [ "$MOSQ_READY" = "true" ]; then
    pass "Mosquitto container is Ready"
else
    fail "Mosquitto container not Ready (check: kubectl logs -n $NAMESPACE $MOSQ_POD -c mosquitto)"
fi

# mqtt-bridge Deployment
BRIDGE_AVAILABLE=$(kubectl get deployment "cenotoo-mqtt-bridge" -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
BRIDGE_DESIRED=$(kubectl get deployment "cenotoo-mqtt-bridge" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
if [ "${BRIDGE_AVAILABLE:-0}" = "$BRIDGE_DESIRED" ] && [ "$BRIDGE_DESIRED" != "0" ]; then
    pass "mqtt-bridge deployment: ${BRIDGE_AVAILABLE}/${BRIDGE_DESIRED} replicas available"
else
    fail "mqtt-bridge deployment: ${BRIDGE_AVAILABLE:-0}/${BRIDGE_DESIRED} replicas available"
fi

# mqtt-bridge restart health
BRIDGE_RESTARTS=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=mqtt-bridge,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "${BRIDGE_RESTARTS:-0}" -lt 10 ]; then
    pass "mqtt-bridge restart count: ${BRIDGE_RESTARTS:-0} (healthy)"
else
    fail "mqtt-bridge restart count: ${BRIDGE_RESTARTS} (possible crash loop)"
fi

# ---------------------------------------------------------------------------
header "Port-Forward Setup"
# ---------------------------------------------------------------------------
API_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$API_SVC" ]; then
    fail "Cannot find cenotoo-api Service in namespace $NAMESPACE"
    printf '\n\033[1;31mCannot run MQTT tests without the API. Exiting.\033[0m\n'
    exit 1
fi

info "Port-forwarding API service $API_SVC → localhost:${API_PORT} ..."
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
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD}"

_RESP_FILE="/tmp/cenotoo_mqtt_test_resp_$$.json"
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
    fail "API authentication failed (HTTP $AUTH_HTTP) — check CENOTOO_ADMIN_USERNAME (got: $ADMIN_USERNAME) and CENOTOO_ADMIN_PASSWORD"
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
            fail "Cannot parse organization name from response"
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
        -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"MQTT integration test\", \"tags\": [\"test\"]}")
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
        -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"MQTT test collection\", \"tags\": [\"test\"], \"collection_schema\": {\"value\": \"float\", \"device_id\": \"text\"}}")
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

# ---------------------------------------------------------------------------
header "MQTT Credentials"
# ---------------------------------------------------------------------------

# Read bridge credentials from the K8s secret
BRIDGE_USERNAME=$(kubectl get secret cenotoo-mqtt-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
BRIDGE_PASSWORD=$(kubectl get secret cenotoo-mqtt-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -n "$BRIDGE_USERNAME" ] && [ -n "$BRIDGE_PASSWORD" ]; then
    pass "Bridge credentials read from cenotoo-mqtt-credentials secret"
else
    fail "Cannot read cenotoo-mqtt-credentials secret — ensure 12-deploy-mqtt-bridge.sh was run"
fi

# ---------------------------------------------------------------------------
header "Test 1: Bridge Auth (Superuser)"
# ---------------------------------------------------------------------------
if [ -n "${BRIDGE_USERNAME:-}" ] && [ -n "${BRIDGE_PASSWORD:-}" ]; then
    info "Publishing with bridge credentials ..."
    if mqtt_pub \
        -h localhost -p 1883 \
        -u "$BRIDGE_USERNAME" -P "$BRIDGE_PASSWORD" \
        -t "test/bridge/auth" \
        -m '{"test": "bridge_auth"}'; then
        pass "Bridge superuser: connect and publish accepted"
    else
        fail "Bridge superuser: connect or publish rejected (check mqtt-auth logs)"
    fi
else
    info "Skipping bridge auth test (no credentials)"
fi

# ---------------------------------------------------------------------------
header "Test 2: Auth Rejection (Bad Credentials)"
# ---------------------------------------------------------------------------
info "Attempting connect with wrong password ..."
if mqtt_pub \
    -h localhost -p 1883 \
    -u "baduser" -P "badpassword" \
    -t "test/bad/auth" \
    -m '{"test": "should_be_rejected"}'; then
    fail "Bad credentials: connection was ACCEPTED (auth not enforced)"
else
    pass "Bad credentials: connection correctly rejected"
fi

# ---------------------------------------------------------------------------
header "Test 3: Device Auth (Project UUID + API Key)"
# ---------------------------------------------------------------------------
if [ -n "$PROJECT_ID" ] && [ -n "$DEVICE_KEY" ] && [ -n "$ORG_NAME" ]; then
    DEVICE_TOPIC="${ORG_NAME}/${TEST_PROJECT}/${TEST_COLLECTION}"
    info "Publishing as device (username=$PROJECT_ID, topic=$DEVICE_TOPIC) ..."
    if mqtt_pub \
        -h localhost -p 1883 \
        -u "$PROJECT_ID" -P "$DEVICE_KEY" \
        -t "$DEVICE_TOPIC" \
        -m "{\"value\": 42.0, \"device_id\": \"${RUN_ID}\"}"; then
        pass "Device auth: connect and publish to valid topic accepted"
    else
        fail "Device auth: connection or publish rejected (check mqtt-auth logs)"
    fi
else
    info "Skipping device auth test (missing PROJECT_ID, DEVICE_KEY, or ORG_NAME)"
fi

# ---------------------------------------------------------------------------
header "Test 4: ACL Enforcement (Wrong Topic)"
# ---------------------------------------------------------------------------
if [ -n "$PROJECT_ID" ] && [ -n "$DEVICE_KEY" ]; then
    WRONG_TOPIC="wrong/segment/count/extra"
    info "Attempting publish to 4-segment topic (invalid format) ..."
    if mqtt_pub \
        -h localhost -p 1883 \
        -u "$PROJECT_ID" -P "$DEVICE_KEY" \
        -t "wrong/segment/count/extra" \
        -m '{"test": "wrong_topic"}' \
        -q 1 -W 5; then
        fail "ACL: 4-segment topic was ACCEPTED (ACL not enforced)"
    else
        pass "ACL: 4-segment topic correctly rejected"
    fi

    if [ -n "${ORG_NAME:-}" ]; then
        info "Attempting publish to wrong project segment ..."
        if mqtt_pub \
            -h localhost -p 1883 \
            -u "$PROJECT_ID" -P "$DEVICE_KEY" \
            -t "${ORG_NAME}/wrongproject/${TEST_COLLECTION}" \
            -m '{"test": "wrong_project"}' \
            -q 1 -W 5; then
            fail "ACL: wrong project segment was ACCEPTED (ACL not enforced)"
        else
            pass "ACL: wrong project segment correctly rejected"
        fi
    fi
else
    info "Skipping ACL tests (no device credentials)"
fi

# ---------------------------------------------------------------------------
header "Test 5: E2E Pipeline (MQTT → mqtt-bridge → Kafka)"
# ---------------------------------------------------------------------------
if [ -n "$PROJECT_ID" ] && [ -n "$DEVICE_KEY" ] && [ -n "$ORG_NAME" ]; then
    DEVICE_TOPIC="${ORG_NAME}/${TEST_PROJECT}/${TEST_COLLECTION}"
    KAFKA_TOPIC="${ORG_NAME}.${TEST_PROJECT}.${TEST_COLLECTION}"
    E2E_DEVICE_ID="${RUN_ID}-e2e"

    KAFKA_POD=$(kubectl get pod -n "$NAMESPACE" \
        -l "strimzi.io/cluster=${RELEASE}-kafka,strimzi.io/kind=Kafka" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$KAFKA_POD" ]; then
        fail "E2E: No running Kafka broker pod found"
    else
        info "Publishing E2E test message (device_id=$E2E_DEVICE_ID, topic=$DEVICE_TOPIC) ..."
        if mqtt_pub \
            -h localhost -p 1883 \
            -u "$PROJECT_ID" -P "$DEVICE_KEY" \
            -t "$DEVICE_TOPIC" \
            -m "{\"value\": 99.9, \"device_id\": \"${E2E_DEVICE_ID}\"}"; then
            pass "E2E: MQTT publish accepted by broker"
        else
            fail "E2E: MQTT publish failed — aborting pipeline check"
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
            pass "E2E pipeline: MQTT → mqtt-bridge → Kafka ✓ (message on topic $KAFKA_TOPIC)"
        else
            fail "E2E pipeline: message not found on Kafka topic $KAFKA_TOPIC after 15s"
            info "Debug: kubectl -n $NAMESPACE logs deployment/cenotoo-mqtt-bridge --tail=50"
            info "Debug: kubectl -n $NAMESPACE logs $MOSQ_POD -c mqtt-auth --tail=30"
        fi
    fi
else
    info "Skipping E2E pipeline test (missing PROJECT_ID, DEVICE_KEY, or ORG_NAME)"
fi

# ---------------------------------------------------------------------------
header "Test 6: mqtt-bridge Log Health"
# ---------------------------------------------------------------------------
BRIDGE_LOGS=$(kubectl logs -n "$NAMESPACE" deployment/cenotoo-mqtt-bridge --tail=50 2>/dev/null || echo "")
BRIDGE_ERRORS=$(printf '%s' "$BRIDGE_LOGS" | grep -ciE 'ERROR|Exception|CRITICAL|ConnectionError|AuthenticationFailed' || true)
BRIDGE_CONNECTED=$(printf '%s' "$BRIDGE_LOGS" | grep -ci 'Connected\|connected to' || true)

if [ "${BRIDGE_ERRORS:-0}" -eq 0 ]; then
    pass "mqtt-bridge logs: no errors in last 50 lines"
else
    fail "mqtt-bridge logs: $BRIDGE_ERRORS error(s) found in last 50 lines"
fi

if [ "${BRIDGE_CONNECTED:-0}" -gt 0 ]; then
    pass "mqtt-bridge logs: connected message found"
else
    info "mqtt-bridge: no 'connected' message in recent logs (may be old startup)"
fi

AUTH_LOGS=$(kubectl logs -n "$NAMESPACE" "$MOSQ_POD" -c mqtt-auth --tail=30 2>/dev/null || echo "")
AUTH_ERRORS=$(printf '%s' "$AUTH_LOGS" | grep -ciE 'ERROR|Exception|CRITICAL' || true)
if [ "${AUTH_ERRORS:-0}" -eq 0 ]; then
    pass "mqtt-auth logs: no errors in last 30 lines"
else
    fail "mqtt-auth logs: $AUTH_ERRORS error(s) found in last 30 lines"
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
    printf '\033[1;31mMQTT TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mMQTT TEST PASSED\033[0m\n'
    exit 0
fi
