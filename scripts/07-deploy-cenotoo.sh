#!/usr/bin/env bash
# =============================================================================
# 07-deploy-cenotoo.sh — Deploy Cenotoo on k3s
# =============================================================================
# Deploys the Cenotoo Helm chart (Kafka + Cassandra + Flink + consumers).
# Uses k3s-specific value overrides (local-path StorageClass).
# Re-running this script is safe (idempotent — uses helm upgrade --install).
#
# Prerequisites: k3s (01), cert-manager (02), Strimzi (03),
#                K8ssandra (04), Flink operator (05)
# Optional:      monitoring stack (06)
# Produces:      Full Cenotoo stack running in cenotoo namespace
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
CHART_DIR="$(cd "$(dirname "$0")/../deploy/helm/cenotoo" && pwd)"
VALUES_OVERRIDE="${CENOTOO_VALUES:-}"  # Extra values file (e.g., values-production.yaml)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# ---------------------------------------------------------------------------
# Step 1 — Preflight checks
# ---------------------------------------------------------------------------
info "Running preflight checks ..."

# Check required CRDs
REQUIRED_CRDS=("kafkas.kafka.strimzi.io" "k8ssandraclusters.k8ssandra.io" "flinkdeployments.flink.apache.org")
for crd in "${REQUIRED_CRDS[@]}"; do
    if kubectl get crd "$crd" &>/dev/null; then
        ok "CRD found: $crd"
    else
        fail "Required CRD not found: $crd — run prerequisite scripts first"
    fi
done

# Check monitoring (warn if missing)
if kubectl get crd prometheusrules.monitoring.coreos.com &>/dev/null; then
    ok "Prometheus Operator CRDs found (monitoring will be enabled)"
    MONITORING_AVAILABLE=true
else
    warn "Prometheus Operator CRDs not found — monitoring resources will be skipped"
    warn "Run 06-install-monitoring.sh to enable monitoring"
    MONITORING_AVAILABLE=false
fi

# ---------------------------------------------------------------------------
# Step 2 — Create namespace
# ---------------------------------------------------------------------------
if kubectl get ns "$NAMESPACE" &>/dev/null; then
    ok "Namespace $NAMESPACE already exists"
else
    info "Creating namespace $NAMESPACE ..."
    kubectl create namespace "$NAMESPACE"
    ok "Namespace $NAMESPACE created"
fi

# ---------------------------------------------------------------------------
# Step 3 — Build Helm values
# ---------------------------------------------------------------------------
# k3s uses local-path as default StorageClass
HELM_ARGS=(
    --namespace "$NAMESPACE"
    --set kafka.storage.storageClassName=local-path
    --set cassandra.storage.storageClassName=local-path
    --set flink.storage.storageClassName=local-path
)

# Disable monitoring if Prometheus Operator is not installed
if [ "$MONITORING_AVAILABLE" = "false" ]; then
    HELM_ARGS+=(--set monitoring.enabled=false)
fi

# Add extra values file if specified
if [ -n "$VALUES_OVERRIDE" ]; then
    if [ -f "$VALUES_OVERRIDE" ]; then
        HELM_ARGS+=(-f "$VALUES_OVERRIDE")
        info "Using values override: $VALUES_OVERRIDE"
    else
        fail "Values file not found: $VALUES_OVERRIDE"
    fi
fi

# ---------------------------------------------------------------------------
# Step 4 — Deploy Cenotoo
# ---------------------------------------------------------------------------
info "Deploying Cenotoo to namespace $NAMESPACE ..."
helm upgrade --install cenotoo "$CHART_DIR" \
    "${HELM_ARGS[@]}" \
    --timeout 10m

ok "Cenotoo Helm release deployed"

# ---------------------------------------------------------------------------
# Step 5 — Show status
# ---------------------------------------------------------------------------
echo ""
info "Cenotoo resources in namespace $NAMESPACE:"
echo ""
echo "--- Kafka ---"
kubectl get kafka,kafkanodepool,kafkauser -n "$NAMESPACE" 2>/dev/null || echo "  (pending)"
echo ""
echo "--- Cassandra ---"
kubectl get k8ssandraclusters,cassandradatacenters -n "$NAMESPACE" 2>/dev/null || echo "  (pending)"
echo ""
echo "--- Flink ---"
kubectl get flinkdeployment -n "$NAMESPACE" 2>/dev/null || echo "  (pending)"
echo ""
echo "--- Consumers ---"
kubectl get deployments -n "$NAMESPACE" -l 'app.kubernetes.io/component in (cassandra-writer,live-consumer)' 2>/dev/null || echo "  (pending)"
echo ""
echo "--- All pods ---"
kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "  (none yet)"
echo ""

ok "Cenotoo deployment initiated"
echo ""
info "Resources may take several minutes to become fully ready."
info "Monitor progress: kubectl get pods -n $NAMESPACE -w"
echo ""
info "Useful commands:"
info "  kubectl get kafka -n $NAMESPACE                    # Kafka cluster status"
info "  kubectl get k8ssandraclusters -n $NAMESPACE        # Cassandra cluster status"
info "  kubectl get flinkdeployment -n $NAMESPACE          # Flink status"
info "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=cassandra-writer  # Consumer logs"
