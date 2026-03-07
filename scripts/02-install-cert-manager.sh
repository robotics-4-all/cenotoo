#!/usr/bin/env bash
# =============================================================================
# 02-install-cert-manager.sh — Install cert-manager
# =============================================================================
# cert-manager is required by K8ssandra Operator (step 04).
# Re-running this script is safe (idempotent).
#
# Prerequisites: k3s running (01-install-k3s.sh), helm
# Produces:      cert-manager deployed in cert-manager namespace
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.4}"
NAMESPACE="cert-manager"

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
    kubectl wait --for=condition=Ready pod \
        -l "$label" -n "$ns" --timeout="${timeout}s" 2>/dev/null || true
    # Fallback: poll until at least one pod is Running
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
info "Adding Jetstack Helm repo ..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

# ---------------------------------------------------------------------------
# Step 2 — Install cert-manager
# ---------------------------------------------------------------------------
if helm status cert-manager -n "$NAMESPACE" &>/dev/null; then
    ok "cert-manager is already installed"
    info "Upgrading to $CERT_MANAGER_VERSION ..."
    helm upgrade cert-manager jetstack/cert-manager \
        --namespace "$NAMESPACE" \
        --version "$CERT_MANAGER_VERSION" \
        --set crds.enabled=true \
        --wait
else
    info "Installing cert-manager $CERT_MANAGER_VERSION ..."
    helm install cert-manager jetstack/cert-manager \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --set crds.enabled=true \
        --wait
fi

# ---------------------------------------------------------------------------
# Step 3 — Verify
# ---------------------------------------------------------------------------
wait_for_pods "$NAMESPACE" "app.kubernetes.io/instance=cert-manager"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
ok "cert-manager $CERT_MANAGER_VERSION is running"
echo ""
info "Next step: ./scripts/03-install-strimzi-operator.sh"
