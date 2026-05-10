#!/usr/bin/env bash
# =============================================================================
# 02-install-cert-manager.sh — Ensure cert-manager is available
# =============================================================================
# cert-manager is required by Flink Operator (webhook certificates).
# Re-running this script is safe (idempotent).
#
# If cert-manager is already installed (by another project or manually),
# this script reuses it — it does NOT upgrade or modify the existing
# installation. Use CERT_MANAGER_FORCE_INSTALL=true to override.
#
# Uses kubectl apply (not Helm) to avoid ownership conflicts with
# other projects that may share the same cert-manager installation.
#
# Prerequisites: k3s running (01-install-k3s.sh)
# Produces:      cert-manager deployed in cert-manager namespace
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
NAMESPACE="cert-manager"
FORCE_INSTALL="${CERT_MANAGER_FORCE_INSTALL:-false}"
MANIFEST_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

cert_manager_healthy() {
    local total ready
    total=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    ready=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | awk '{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") c++} END{print c+0}')
    [ "$total" -ge 3 ] && [ "$ready" -eq "$total" ]
}

# ---------------------------------------------------------------------------
# Step 1 — Detect existing cert-manager
# ---------------------------------------------------------------------------
if kubectl get crd certificates.cert-manager.io &>/dev/null; then
    info "cert-manager CRDs detected in cluster"

    if [ "$FORCE_INSTALL" != "true" ] && cert_manager_healthy; then
        ok "cert-manager is already running and healthy"
        kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || true
        echo ""
        ok "Reusing existing cert-manager installation"
        echo ""
        info "Next step: ./scripts/03-install-strimzi-operator.sh"
        exit 0
    fi

    if [ "$FORCE_INSTALL" != "true" ]; then
        warn "cert-manager CRDs exist but pods are not healthy"
        warn "Set CERT_MANAGER_FORCE_INSTALL=true to reinstall"
        echo ""
        kubectl get pods -n "$NAMESPACE" 2>/dev/null || true
        echo ""
        fail "cert-manager is unhealthy. Use CERT_MANAGER_FORCE_INSTALL=true to override."
    fi

    warn "CERT_MANAGER_FORCE_INSTALL=true — reinstalling cert-manager $CERT_MANAGER_VERSION"
fi

# ---------------------------------------------------------------------------
# Step 2 — Install cert-manager via kubectl apply
# ---------------------------------------------------------------------------
info "Installing cert-manager $CERT_MANAGER_VERSION ..."
kubectl apply -f "$MANIFEST_URL"

# ---------------------------------------------------------------------------
# Step 3 — Wait for deployments
# ---------------------------------------------------------------------------
info "Waiting for cert-manager deployments ..."
kubectl wait --for=condition=available deployment --all \
    -n "$NAMESPACE" --timeout=120s

# ---------------------------------------------------------------------------
# Step 4 — Verify
# ---------------------------------------------------------------------------
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
ok "cert-manager $CERT_MANAGER_VERSION is running"
echo ""
info "Next step: ./scripts/03-install-strimzi-operator.sh"
