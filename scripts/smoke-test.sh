#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh — Verify Cenotoo deployment health on k3s
#
# Checks: pods running, CRDs reconciled, endpoints reachable
# Usage:  ./scripts/smoke-test.sh [NAMESPACE] [RELEASE_NAME]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

passed=0
failed=0
warnings=0

pass()  { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()  { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
warn()  { printf '\033[1;33m  WARN\033[0m  %s\n' "$*"; warnings=$((warnings + 1)); }
header(){ printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
header "Namespace"
# ---------------------------------------------------------------------------
if kubectl get ns "$NAMESPACE" &>/dev/null; then
    pass "Namespace $NAMESPACE exists"
else
    fail "Namespace $NAMESPACE not found"
    printf '\n\033[1;31mCannot continue without namespace. Exiting.\033[0m\n'
    exit 1
fi

# ---------------------------------------------------------------------------
header "Pod Health"
# ---------------------------------------------------------------------------
total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [ "$total_pods" -eq 0 ]; then
    fail "No pods found in $NAMESPACE"
else
    running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c 'Running' || true)
    pending=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c 'Pending' || true)
    crash=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cE 'CrashLoopBackOff|Error|ImagePullBackOff' || true)

    if [ "$running" -eq "$total_pods" ]; then
        pass "All $total_pods pods are Running"
    else
        fail "$running/$total_pods pods Running ($pending pending, $crash erroring)"
    fi

    not_ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | awk '{split($2,a,"/"); if(a[1]!=a[2]) print $1}' || true)
    if [ -z "$not_ready" ]; then
        pass "All containers are Ready"
    else
        fail "Containers not ready: $not_ready"
    fi
fi

# ---------------------------------------------------------------------------
header "Kafka (Strimzi)"
# ---------------------------------------------------------------------------
kafka_name="${RELEASE}-kafka"

if kubectl get kafka "$kafka_name" -n "$NAMESPACE" &>/dev/null; then
    kafka_ready=$(kubectl get kafka "$kafka_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$kafka_ready" = "True" ]; then
        pass "Kafka cluster '$kafka_name' is Ready"
    else
        fail "Kafka cluster '$kafka_name' status: $kafka_ready"
    fi

    broker_count=$(kubectl get pods -n "$NAMESPACE" \
        -l "strimzi.io/cluster=$kafka_name,strimzi.io/kind=Kafka" \
        --no-headers 2>/dev/null | grep -c 'Running' || true)
    pass "Kafka brokers running: $broker_count"
else
    fail "Kafka CR '$kafka_name' not found"
fi

if kubectl get kafkanodepool "${RELEASE}-controller" -n "$NAMESPACE" &>/dev/null; then
    pass "KafkaNodePool '${RELEASE}-controller' exists"
else
    fail "KafkaNodePool '${RELEASE}-controller' not found"
fi

if kubectl get kafkanodepool "${RELEASE}-broker" -n "$NAMESPACE" &>/dev/null; then
    pass "KafkaNodePool '${RELEASE}-broker' exists"
else
    fail "KafkaNodePool '${RELEASE}-broker' not found"
fi

if kubectl get kafkauser "${RELEASE}-consumer" -n "$NAMESPACE" &>/dev/null; then
    pass "KafkaUser '${RELEASE}-consumer' exists"
else
    warn "KafkaUser '${RELEASE}-consumer' not found"
fi

# ---------------------------------------------------------------------------
header "Cassandra (K8ssandra)"
# ---------------------------------------------------------------------------
cassandra_name="${RELEASE}-cassandra"

if kubectl get k8ssandraclusters "$cassandra_name" -n "$NAMESPACE" &>/dev/null; then
    pass "K8ssandraCluster '$cassandra_name' exists"

    cass_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l "app.kubernetes.io/managed-by=cassandra-operator" \
        --no-headers 2>/dev/null | grep -c 'Running' || true)
    if [ "$cass_pods" -gt 0 ]; then
        pass "Cassandra nodes running: $cass_pods"
    else
        fail "No Cassandra pods running"
    fi
else
    fail "K8ssandraCluster '$cassandra_name' not found"
fi

# ---------------------------------------------------------------------------
header "Flink (Flink Operator)"
# ---------------------------------------------------------------------------
flink_name="${RELEASE}-flink"

if kubectl get flinkdeployment "$flink_name" -n "$NAMESPACE" &>/dev/null; then
    flink_state=$(kubectl get flinkdeployment "$flink_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.jobManagerDeploymentStatus}' 2>/dev/null || echo "Unknown")
    if [ "$flink_state" = "READY" ]; then
        pass "FlinkDeployment '$flink_name' JobManager is READY"
    else
        warn "FlinkDeployment '$flink_name' JobManager status: $flink_state"
    fi
else
    fail "FlinkDeployment '$flink_name' not found"
fi

# ---------------------------------------------------------------------------
header "Consumers"
# ---------------------------------------------------------------------------
for component in cassandra-writer live-consumer; do
    deploy_name="${RELEASE}-${component}"
    if kubectl get deployment "$deploy_name" -n "$NAMESPACE" &>/dev/null; then
        available=$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" \
            -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get deployment "$deploy_name" -n "$NAMESPACE" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
        if [ "${available:-0}" = "$desired" ] && [ "$desired" != "0" ]; then
            pass "$deploy_name: $available/$desired replicas available"
        else
            fail "$deploy_name: ${available:-0}/$desired replicas available"
        fi
    else
        fail "Deployment '$deploy_name' not found"
    fi
done

# ---------------------------------------------------------------------------
header "Service Endpoints"
# ---------------------------------------------------------------------------
kafka_bootstrap_svc="${kafka_name}-kafka-bootstrap"
if kubectl get svc "$kafka_bootstrap_svc" -n "$NAMESPACE" &>/dev/null; then
    pass "Kafka bootstrap service exists: $kafka_bootstrap_svc"

    kafka_ep=$(kubectl get endpoints "$kafka_bootstrap_svc" -n "$NAMESPACE" \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    if [ -n "$kafka_ep" ]; then
        pass "Kafka bootstrap has endpoints"
    else
        fail "Kafka bootstrap has no endpoints"
    fi
else
    fail "Kafka bootstrap service not found"
fi

cass_svc=$(kubectl get svc -n "$NAMESPACE" -l "app.kubernetes.io/managed-by=cassandra-operator" \
    --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [ -n "$cass_svc" ]; then
    pass "Cassandra service exists: $cass_svc"
else
    warn "No Cassandra service found (may still be provisioning)"
fi

# ---------------------------------------------------------------------------
header "Summary"
# ---------------------------------------------------------------------------
total=$((passed + failed + warnings))
printf '\n  \033[1;32m%d passed\033[0m' "$passed"
if [ "$failed" -gt 0 ]; then
    printf ', \033[1;31m%d failed\033[0m' "$failed"
fi
if [ "$warnings" -gt 0 ]; then
    printf ', \033[1;33m%d warnings\033[0m' "$warnings"
fi
printf ' (out of %d checks)\n\n' "$total"

if [ "$failed" -gt 0 ]; then
    printf '\033[1;31mSMOKE TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mSMOKE TEST PASSED\033[0m\n'
    exit 0
fi
