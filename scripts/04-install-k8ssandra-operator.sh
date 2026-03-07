#!/usr/bin/env bash
# =============================================================================
# 04-install-k8ssandra-operator.sh — Install K8ssandra Operator
# =============================================================================
# K8ssandra manages Cassandra clusters via K8ssandraCluster CRDs.
# Includes cass-operator under the hood.
# Requires cert-manager (step 02).
# Re-running this script is safe (idempotent).
#
# Prerequisites: k3s (01), cert-manager (02)
# Produces:      K8ssandra operator deployed, Cassandra CRDs registered
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
K8SSANDRA_VERSION="${K8SSANDRA_VERSION:-1.24.0}"
NAMESPACE="k8ssandra-operator"

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
# Step 1 — Verify cert-manager is running
# ---------------------------------------------------------------------------
info "Checking cert-manager ..."
if ! kubectl get ns cert-manager &>/dev/null; then
    fail "cert-manager namespace not found. Run 02-install-cert-manager.sh first."
fi
if ! kubectl get pods -n cert-manager -l app.kubernetes.io/instance=cert-manager \
    --no-headers 2>/dev/null | grep -q 'Running'; then
    fail "cert-manager pods are not running. Run 02-install-cert-manager.sh first."
fi
ok "cert-manager is running"

# ---------------------------------------------------------------------------
# Step 2 — Add Helm repo
# ---------------------------------------------------------------------------
info "Adding K8ssandra Helm repo ..."
helm repo add k8ssandra https://helm.k8ssandra.io/stable --force-update
helm repo update k8ssandra

# ---------------------------------------------------------------------------
# Step 3 — Install K8ssandra operator
# ---------------------------------------------------------------------------
if helm status k8ssandra-operator -n "$NAMESPACE" &>/dev/null; then
    ok "K8ssandra operator is already installed"
    info "Upgrading to $K8SSANDRA_VERSION ..."
    helm upgrade k8ssandra-operator k8ssandra/k8ssandra-operator \
        --namespace "$NAMESPACE" \
        --version "$K8SSANDRA_VERSION" \
        --wait
else
    info "Installing K8ssandra operator $K8SSANDRA_VERSION ..."
    helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --version "$K8SSANDRA_VERSION" \
        --wait
fi

# ---------------------------------------------------------------------------
# Step 4 — Verify
# ---------------------------------------------------------------------------
wait_for_pods "$NAMESPACE" "app.kubernetes.io/name=k8ssandra-operator"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
info "Registered Cassandra CRDs:"
kubectl get crd | grep -E 'k8ssandra|cassandra' || warn "No Cassandra CRDs found yet"
echo ""
ok "K8ssandra operator $K8SSANDRA_VERSION is running"
echo ""
info "Next step: ./scripts/05-install-flink-operator.sh"
