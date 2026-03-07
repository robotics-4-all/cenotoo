#!/usr/bin/env bash
# =============================================================================
# integration-test.sh — End-to-end Kafka → Cassandra data flow test
#
# Produces a message to Kafka, then verifies it can be consumed.
# Writes directly to Cassandra, then verifies the read.
# Tests the core data path that Cenotoo consumers rely on.
#
# Usage:  ./scripts/integration-test.sh [NAMESPACE] [RELEASE_NAME]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"
TEST_TOPIC="cenotoo.integration.test"
TEST_KEYSPACE="cenotoo_integration_test"
TEST_TABLE="integration_test_data"
TEST_ID="test-$(date +%s)"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

passed=0
failed=0

pass()  { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()  { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()  { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header(){ printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

cleanup() {
    info "Cleaning up test resources ..."
    if [ -n "${CASS_POD:-}" ]; then
        kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
            cqlsh -u cassandra -p cassandra -e "DROP KEYSPACE IF EXISTS ${TEST_KEYSPACE};" 2>/dev/null || true
    fi
    if [ -n "${KAFKA_POD:-}" ]; then
        kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
            /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
            --delete --topic "$TEST_TOPIC" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
header "Locate Pods"
# ---------------------------------------------------------------------------
KAFKA_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "strimzi.io/cluster=${RELEASE}-kafka,strimzi.io/kind=Kafka" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$KAFKA_POD" ]; then
    fail "No Kafka broker pod found"
    printf '\n\033[1;31mCannot run integration tests without Kafka. Exiting.\033[0m\n'
    exit 1
fi
pass "Kafka broker pod: $KAFKA_POD"

CASS_POD=$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/managed-by=cassandra-operator" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$CASS_POD" ]; then
    fail "No Cassandra pod found"
    printf '\n\033[1;31mCannot run integration tests without Cassandra. Exiting.\033[0m\n'
    exit 1
fi
pass "Cassandra pod: $CASS_POD"

# ---------------------------------------------------------------------------
header "Test 1: Kafka Produce & Consume"
# ---------------------------------------------------------------------------
info "Creating test topic: $TEST_TOPIC"
kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
    --create --topic "$TEST_TOPIC" --partitions 1 --replication-factor 1 \
    --if-not-exists 2>&1 | grep -v "^$" || true

info "Producing test message ..."
TEST_PAYLOAD="{\"sensor_id\": \"${TEST_ID}\", \"temperature\": 22.5, \"humidity\": 60}"
printf '%s' "$TEST_PAYLOAD" | kubectl exec -i -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
    --topic "$TEST_TOPIC" 2>/dev/null

info "Consuming message back (5s timeout) ..."
CONSUMED=$(kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
    --topic "$TEST_TOPIC" --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null || echo "")

if echo "$CONSUMED" | grep -q "$TEST_ID"; then
    pass "Kafka round-trip: produced and consumed message successfully"
else
    fail "Kafka round-trip: message not consumed (got: '${CONSUMED}')"
fi

# ---------------------------------------------------------------------------
header "Test 2: Cassandra Write & Read"
# ---------------------------------------------------------------------------
info "Creating test keyspace: $TEST_KEYSPACE"
kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
    cqlsh -u cassandra -p cassandra -e "
        CREATE KEYSPACE IF NOT EXISTS ${TEST_KEYSPACE}
        WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1};
    " 2>&1 | grep -v "^$" || true

info "Creating test table: $TEST_TABLE"
kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
    cqlsh -u cassandra -p cassandra -e "
        CREATE TABLE IF NOT EXISTS ${TEST_KEYSPACE}.${TEST_TABLE} (
            sensor_id TEXT PRIMARY KEY,
            temperature DOUBLE,
            humidity DOUBLE
        );
    " 2>&1 | grep -v "^$" || true

info "Inserting test row ..."
kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
    cqlsh -u cassandra -p cassandra -e "
        INSERT INTO ${TEST_KEYSPACE}.${TEST_TABLE} (sensor_id, temperature, humidity)
        VALUES ('${TEST_ID}', 22.5, 60.0);
    " 2>&1 | grep -v "^$" || true

info "Reading back ..."
READ_RESULT=$(kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
    cqlsh -u cassandra -p cassandra -e "
        SELECT sensor_id, temperature, humidity FROM ${TEST_KEYSPACE}.${TEST_TABLE}
        WHERE sensor_id = '${TEST_ID}';
    " 2>/dev/null || echo "")

if echo "$READ_RESULT" | grep -q "$TEST_ID"; then
    pass "Cassandra round-trip: wrote and read row successfully"
else
    fail "Cassandra round-trip: row not found (got: '${READ_RESULT}')"
fi

# ---------------------------------------------------------------------------
header "Test 3: Kafka Topic Listing"
# ---------------------------------------------------------------------------
TOPICS=$(kubectl exec -n "$NAMESPACE" "$KAFKA_POD" -- \
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null || echo "")

if [ -n "$TOPICS" ]; then
    topic_count=$(echo "$TOPICS" | wc -l)
    pass "Kafka topic listing works ($topic_count topics)"
else
    fail "Cannot list Kafka topics"
fi

# ---------------------------------------------------------------------------
header "Test 4: Cassandra System Query"
# ---------------------------------------------------------------------------
KEYSPACES=$(kubectl exec -n "$NAMESPACE" "$CASS_POD" -c cassandra -- \
    cqlsh -u cassandra -p cassandra -e "SELECT keyspace_name FROM system_schema.keyspaces;" \
    2>/dev/null || echo "")

if echo "$KEYSPACES" | grep -q "system"; then
    pass "Cassandra system query works"
else
    fail "Cannot query Cassandra system tables"
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
