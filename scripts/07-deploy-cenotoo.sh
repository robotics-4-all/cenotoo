#!/usr/bin/env bash
# =============================================================================
# 07-deploy-cenotoo.sh — Deploy Cenotoo on k3s (kubectl apply)
# =============================================================================
# Applies manifests in dependency order: secrets -> kafka -> cassandra -> flink -> consumers -> api.
# Re-running is safe (kubectl apply is idempotent).
#
# Prerequisites: k3s (01), cert-manager (02), Strimzi (03), Flink operator (05)
# Optional:      monitoring stack (06)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="$(cd "$SCRIPT_DIR/../deploy/k8s" && pwd)"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

wait_for_pods() {
    local ns="$1" label="$2" timeout="${3:-300}" expected="${4:-1}"
    info "Waiting for pods ($label) ..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local ready
        ready=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null \
            | grep -c '1/1\|2/2\|Running' || true)
        if [ "$ready" -ge "$expected" ]; then return 0; fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Pods ($label) in $ns not ready within ${timeout}s"
}

wait_for_cassandra() {
    local ns="$1" timeout="${2:-300}"
    info "Waiting for Cassandra to be ready ..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local phase ready
        phase=$(kubectl get pod cenotoo-cassandra-0 -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        ready=$(kubectl get pod cenotoo-cassandra-0 -n "$ns" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then return 0; fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Cassandra not ready within ${timeout}s"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
info "Running preflight checks ..."

REQUIRED_CRDS=("kafkas.kafka.strimzi.io" "flinkdeployments.flink.apache.org")
for crd in "${REQUIRED_CRDS[@]}"; do
    if kubectl get crd "$crd" &>/dev/null; then
        ok "CRD found: $crd"
    else
        fail "Required CRD not found: $crd"
    fi
done

REQUIRED_IMAGES=("kafka-cassandra-consumer" "kafka-live-consumer" "custom-flink-image" "cenotoo-api")
images_missing=false
for img in "${REQUIRED_IMAGES[@]}"; do
    if sudo k3s ctr images list 2>/dev/null | grep -q "$img"; then
        ok "Image found: $img"
    else
        warn "Image not found: $img"
        images_missing=true
    fi
done
if [ "$images_missing" = "true" ]; then
    warn "Run: ./scripts/build-images.sh --k3s"
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
info "Applying namespace ..."
kubectl apply -f "$MANIFEST_DIR/00-namespace.yaml"

info "Applying secrets ..."
for example_file in "$MANIFEST_DIR"/01-secrets/*.yaml.example; do
    target="${example_file%.example}"
    if [ ! -f "$target" ]; then
        cp "$example_file" "$target"
        warn "$(basename "$target") not found — using defaults from $(basename "$example_file")"
    fi
done
kubectl apply -f "$MANIFEST_DIR/01-secrets/" -n "$NAMESPACE"

info "Applying Kafka (Strimzi) ..."
kubectl apply -f "$MANIFEST_DIR/02-kafka/" -n "$NAMESPACE"
wait_for_pods "$NAMESPACE" "strimzi.io/cluster=cenotoo-kafka,strimzi.io/kind=Kafka" 600 1
ok "Kafka is running"

info "Applying Cassandra ..."
kubectl apply -f "$MANIFEST_DIR/03-cassandra/" -n "$NAMESPACE"
wait_for_cassandra "$NAMESPACE" 300
ok "Cassandra is ready"

info "Applying Flink ..."
kubectl apply -f "$MANIFEST_DIR/04-flink/" -n "$NAMESPACE"

info "Applying consumers ..."
kubectl apply -f "$MANIFEST_DIR/05-consumers/" -n "$NAMESPACE"

info "Applying API ..."
kubectl apply -f "$MANIFEST_DIR/07-api/" -n "$NAMESPACE"

if kubectl get crd prometheusrules.monitoring.coreos.com &>/dev/null; then
    if [ -d "$MANIFEST_DIR/06-monitoring" ] && [ "$(ls -A "$MANIFEST_DIR/06-monitoring" 2>/dev/null)" ]; then
        info "Applying monitoring ..."
        kubectl apply -f "$MANIFEST_DIR/06-monitoring/" -n "$NAMESPACE"
    fi
else
    warn "Prometheus Operator not found — skipping monitoring"
fi

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
echo ""
echo "--- All pods ---"
kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  (none yet)"
echo ""
ok "Cenotoo deployment complete"
info "Monitor: kubectl get pods -n $NAMESPACE -w"
