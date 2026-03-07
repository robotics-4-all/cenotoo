#!/usr/bin/env bash
# =============================================================================
# 03-install-strimzi-operator.sh — Install Strimzi Kafka Operator
# =============================================================================
# Strimzi manages Kafka clusters via KafkaNodePool and Kafka CRDs.
# The operator watches all namespaces by default.
# Re-running this script is safe (idempotent).
#
# Prerequisites: k3s running (01), cert-manager optional but recommended
# Produces:      Strimzi operator deployed, Kafka CRDs registered
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
STRIMZI_VERSION="${STRIMZI_VERSION:-0.51.0}"
NAMESPACE="strimzi"

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
info "Adding Strimzi Helm repo ..."
helm repo add strimzi https://strimzi.io/charts/ --force-update
helm repo update strimzi

# ---------------------------------------------------------------------------
# Step 2 — Install Strimzi operator
# ---------------------------------------------------------------------------
if helm status strimzi-kafka-operator -n "$NAMESPACE" &>/dev/null; then
    ok "Strimzi operator is already installed"
    info "Upgrading to $STRIMZI_VERSION ..."
    helm upgrade strimzi-kafka-operator strimzi/strimzi-kafka-operator \
        --namespace "$NAMESPACE" \
        --version "$STRIMZI_VERSION" \
        --set watchAnyNamespace=true \
        --wait
else
    info "Installing Strimzi operator $STRIMZI_VERSION ..."
    helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --version "$STRIMZI_VERSION" \
        --set watchAnyNamespace=true \
        --wait
fi

# ---------------------------------------------------------------------------
# Step 3 — Verify
# ---------------------------------------------------------------------------
wait_for_pods "$NAMESPACE" "name=strimzi-cluster-operator"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
info "Registered Kafka CRDs:"
kubectl get crd | grep -E 'kafka|strimzi' || warn "No Kafka CRDs found yet"
echo ""
ok "Strimzi operator $STRIMZI_VERSION is running"
echo ""
info "Next step: ./scripts/04-install-k8ssandra-operator.sh"
