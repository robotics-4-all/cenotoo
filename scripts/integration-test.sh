#!/usr/bin/env bash
# =============================================================================
# integration-test.sh — End-to-end infrastructure verification for Cenotoo
#
# Tests the full data pipeline on a running k3s cluster:
#   1. Kafka produce & consume (with SCRAM-SHA-512 auth)
#   2. Cassandra write & read (with password auth)
#   3. E2E pipeline: Kafka → cassandra-writer consumer → Cassandra
#   4. Consumer health checks
#
# Usage:  sudo ./scripts/integration-test.sh [NAMESPACE] [RELEASE_NAME]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"
TEST_TOPIC="cenotoo.integration.test"
TEST_KEYSPACE="cenotoo_integration_test"
TEST_TABLE="integration_test_data"
TEST_ID="integ-$(date +%s)"

E2E_TOPIC="cenotoo.demo.sensors"
E2E_KEYSPACE="cenotoo"
E2E_TABLE="demo_sensors"
E2E_ID="e2e-$(date +%s)"

KAFKA_USER="${RELEASE}-consumer"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

passed=0
failed=0

pass()  { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()  { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()  { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header(){ printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

run_cql() {
    kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
        cqlsh -u cassandra -p cassandra -e "$1" < /dev/null 2>/dev/null
}

cleanup() {
    info "Cleaning up test resources ..."
    # Drop isolated test keyspace (NOT the E2E keyspace — leave real data intact)
    if [ -n "${CASS_POD:-}" ]; then
        run_cql "DROP KEYSPACE IF EXISTS ${TEST_KEYSPACE};" || true
        run_cql "DELETE FROM ${E2E_KEYSPACE}.${E2E_TABLE} WHERE key = '${E2E_ID}';" || true
    fi
    # Delete isolated test topic (NOT the E2E topic)
    if [ -n "${KAFKA_POD:-}" ] && [ -n "${SASL_READY:-}" ]; then
        kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
            --command-config /tmp/test-client.properties \
            --delete --topic "$TEST_TOPIC" >/dev/null 2>&1 || true
        kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
            rm -f /tmp/test-client.properties 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
header "Locate Pods & Credentials"
# ---------------------------------------------------------------------------
KAFKA_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "strimzi.io/cluster=${RELEASE}-kafka,strimzi.io/kind=Kafka" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$KAFKA_POD" ]; then
    fail "No running Kafka broker pod found"
    printf '\n\033[1;31mCannot run integration tests without Kafka. Exiting.\033[0m\n'
    exit 1
fi
pass "Kafka broker pod: $KAFKA_POD"

CASS_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=cassandra,app.kubernetes.io/part-of=${RELEASE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$CASS_POD" ]; then
    fail "No running Cassandra pod found"
    printf '\n\033[1;31mCannot run integration tests without Cassandra. Exiting.\033[0m\n'
    exit 1
fi
pass "Cassandra pod: $CASS_POD"

KAFKA_PASS=$(kubectl get secret "$KAFKA_USER" -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

if [ -z "$KAFKA_PASS" ]; then
    fail "Cannot retrieve Kafka password from secret '$KAFKA_USER'"
    printf '\n\033[1;31mKafka SASL credentials required. Exiting.\033[0m\n'
    exit 1
fi
pass "Kafka credentials retrieved for user: $KAFKA_USER"

kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- bash -c "cat > /tmp/test-client.properties <<'PROPS'
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${KAFKA_USER}\" password=\"${KAFKA_PASS}\";
PROPS" 2>/dev/null
SASL_READY=1
pass "SASL client config created in broker pod"

# ---------------------------------------------------------------------------
header "Test 1: Kafka Produce & Consume"
# ---------------------------------------------------------------------------
info "Creating test topic: $TEST_TOPIC"
kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
    --command-config /tmp/test-client.properties \
    --create --topic "$TEST_TOPIC" --partitions 1 --replication-factor 1 \
    --if-not-exists 2>&1 | grep -v "^$" || true

info "Producing test message ..."
TEST_PAYLOAD="{\"sensor_id\": \"${TEST_ID}\", \"temperature\": 22.5, \"humidity\": 60}"
printf '%s\n' "$TEST_PAYLOAD" | kubectl exec -i -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
    --command-config /tmp/test-client.properties \
    --topic "$TEST_TOPIC" 2>/dev/null

info "Consuming message back (10s timeout) ..."
CONSUMED=$(kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
    --command-config /tmp/test-client.properties \
    --topic "$TEST_TOPIC" --from-beginning --timeout-ms 10000 \
    2>/dev/null || echo "")

if echo "$CONSUMED" | grep -q "$TEST_ID"; then
    pass "Kafka round-trip: produced and consumed message successfully"
else
    fail "Kafka round-trip: message not consumed (got: '${CONSUMED}')"
fi

# ---------------------------------------------------------------------------
header "Test 2: Cassandra Write & Read"
# ---------------------------------------------------------------------------
info "Creating test keyspace: $TEST_KEYSPACE"
run_cql "CREATE KEYSPACE IF NOT EXISTS ${TEST_KEYSPACE} WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1};" || true

info "Creating test table: $TEST_TABLE"
run_cql "CREATE TABLE IF NOT EXISTS ${TEST_KEYSPACE}.${TEST_TABLE} (sensor_id TEXT PRIMARY KEY, temperature DOUBLE, humidity DOUBLE);" || true

info "Inserting test row ..."
run_cql "INSERT INTO ${TEST_KEYSPACE}.${TEST_TABLE} (sensor_id, temperature, humidity) VALUES ('${TEST_ID}', 22.5, 60.0);" || true

info "Reading back ..."
READ_RESULT=$(run_cql "SELECT sensor_id, temperature, humidity FROM ${TEST_KEYSPACE}.${TEST_TABLE} WHERE sensor_id = '${TEST_ID}';" || echo "")

if echo "$READ_RESULT" | grep -q "$TEST_ID"; then
    pass "Cassandra round-trip: wrote and read row successfully"
else
    fail "Cassandra round-trip: row not found (got: '${READ_RESULT}')"
fi

# ---------------------------------------------------------------------------
header "Test 3: Kafka Topic Listing"
# ---------------------------------------------------------------------------
TOPICS=$(kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
    --command-config /tmp/test-client.properties \
    --list 2>/dev/null || echo "")

if [ -n "$TOPICS" ]; then
    topic_count=$(echo "$TOPICS" | wc -l)
    pass "Kafka topic listing works ($topic_count topics)"
else
    fail "Cannot list Kafka topics"
fi

# ---------------------------------------------------------------------------
header "Test 4: Cassandra System Query"
# ---------------------------------------------------------------------------
KEYSPACES=$(run_cql "SELECT keyspace_name FROM system_schema.keyspaces;" || echo "")

if echo "$KEYSPACES" | grep -q "system"; then
    pass "Cassandra system query works"
else
    fail "Cannot query Cassandra system tables"
fi

# ---------------------------------------------------------------------------
header "Test 5: Consumer Health"
# ---------------------------------------------------------------------------
for component in cassandra-writer live-consumer; do
    deploy_name="${RELEASE}-${component}"
    restarts=$(kubectl get pods -n "$NAMESPACE" \
        -l "app.kubernetes.io/component=${component},app.kubernetes.io/part-of=${RELEASE}" \
        -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")

    recent_logs=$(kubectl logs -n "$NAMESPACE" "deployment/${deploy_name}" \
        --tail=20 2>/dev/null || echo "")
    has_auth_error=$(echo "$recent_logs" | grep -ciE 'AUTHORIZATION_FAILED|AuthenticationFailed|AUTH_ERROR' || true)

    if [ "$has_auth_error" -gt 0 ]; then
        fail "$deploy_name: auth errors in recent logs"
    elif [ "${restarts:-0}" -gt 5 ]; then
        fail "$deploy_name: excessive restarts ($restarts)"
    else
        pass "$deploy_name: healthy (restarts: ${restarts:-0})"
    fi
done

# ---------------------------------------------------------------------------
header "Test 6: E2E Pipeline (Kafka → Consumer → Cassandra)"
# ---------------------------------------------------------------------------
info "Ensuring E2E keyspace and table exist ..."
run_cql "CREATE KEYSPACE IF NOT EXISTS ${E2E_KEYSPACE} WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1};" || true
run_cql "CREATE TABLE IF NOT EXISTS ${E2E_KEYSPACE}.${E2E_TABLE} (key TEXT PRIMARY KEY, temperature DOUBLE, humidity DOUBLE);" || true

info "Producing E2E test message to $E2E_TOPIC (key=$E2E_ID) ..."
printf '%s\n' "${E2E_ID}:{\"temperature\": 42.0, \"humidity\": 99.0}" \
    | kubectl exec -i -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
    --command-config /tmp/test-client.properties \
    --topic "$E2E_TOPIC" \
    --reader-property parse.key=true \
    --reader-property key.separator=: \
    2>/dev/null

info "Waiting for cassandra-writer to process (polling up to 30s) ..."
e2e_found=false
for i in $(seq 1 6); do
    sleep 5
    E2E_RESULT=$(run_cql "SELECT key, temperature, humidity FROM ${E2E_KEYSPACE}.${E2E_TABLE} WHERE key = '${E2E_ID}';" || echo "")

    if echo "$E2E_RESULT" | grep -q "$E2E_ID"; then
        e2e_found=true
        break
    fi
    info "  attempt $i/6 — not yet, retrying ..."
done

if [ "$e2e_found" = true ]; then
    pass "E2E pipeline: message flowed Kafka → cassandra-writer → Cassandra"
    if echo "$E2E_RESULT" | grep -q "42"; then
        pass "E2E pipeline: data values match (temperature=42.0)"
    else
        fail "E2E pipeline: data values mismatch"
    fi
else
    fail "E2E pipeline: message did not arrive in Cassandra within 30s"
    info "Check cassandra-writer logs: kubectl -n $NAMESPACE logs deployment/${RELEASE}-cassandra-writer --tail=50"
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
    printf '\033[1;31mINTEGRATION TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mINTEGRATION TEST PASSED\033[0m\n'
    exit 0
fi
