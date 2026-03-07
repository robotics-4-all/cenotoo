#!/usr/bin/env bash
# =============================================================================
# 05-install-flink-operator.sh — Install Apache Flink Kubernetes Operator
# =============================================================================
# Manages Flink clusters via FlinkDeployment CRDs.
# Re-running this script is safe (idempotent).
#
# Prerequisites: k3s (01), cert-manager (02 — required for webhooks)
# Produces:      Flink operator deployed, FlinkDeployment CRD registered
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FLINK_OPERATOR_VERSION="${FLINK_OPERATOR_VERSION:-1.14.0}"
NAMESPACE="flink"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

wait_for_pods() {
    local ns="$1" label="$2" timeout="${3:-300}"
    info "Waiting for pods in $ns ($label) ..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local ready
        ready=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null \
            | grep -c 'Running' || true)
        if [ "$ready" -gt 0 ]; then return 0; fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Pods ($label) in $ns not ready within ${timeout}s"
}

# ---------------------------------------------------------------------------
# Step 1 — Add Helm repo
# ---------------------------------------------------------------------------
info "Adding Flink Operator Helm repo ..."
helm repo add flink-operator-repo https://downloads.apache.org/flink/flink-kubernetes-operator-${FLINK_OPERATOR_VERSION}/ --force-update 2>/dev/null \
    || helm repo add flink-operator-repo https://archive.apache.org/dist/flink/flink-kubernetes-operator-${FLINK_OPERATOR_VERSION}/ --force-update
helm repo update flink-operator-repo

# ---------------------------------------------------------------------------
# Step 2 — Install Flink operator
# ---------------------------------------------------------------------------
if helm status flink-kubernetes-operator -n "$NAMESPACE" &>/dev/null; then
    ok "Flink operator is already installed"
    info "Upgrading to $FLINK_OPERATOR_VERSION ..."
    helm upgrade flink-kubernetes-operator flink-operator-repo/flink-kubernetes-operator \
        --namespace "$NAMESPACE" \
        --version "$FLINK_OPERATOR_VERSION" \
        --set webhook.create=true \
        --wait
else
    info "Installing Flink operator $FLINK_OPERATOR_VERSION ..."
    helm install flink-kubernetes-operator flink-operator-repo/flink-kubernetes-operator \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --version "$FLINK_OPERATOR_VERSION" \
        --set webhook.create=true \
        --wait
fi

# ---------------------------------------------------------------------------
# Step 3 — Verify
# ---------------------------------------------------------------------------
wait_for_pods "$NAMESPACE" "app.kubernetes.io/name=flink-kubernetes-operator"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
info "Registered Flink CRDs:"
kubectl get crd | grep -E 'flink' || warn "No Flink CRDs found yet"
echo ""
ok "Flink operator $FLINK_OPERATOR_VERSION is running"
echo ""
info "Next step: ./scripts/06-install-monitoring.sh (optional)"
info "Or skip to: ./scripts/07-deploy-cenotoo.sh"
