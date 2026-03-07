#!/usr/bin/env bash
# =============================================================================
# 06-install-monitoring.sh — Install kube-prometheus-stack (OPTIONAL)
# =============================================================================
# Installs Prometheus Operator, Prometheus, Grafana, and Alertmanager.
# Required if monitoring.enabled=true in Cenotoo values (default).
# Re-running this script is safe (idempotent).
#
# Prerequisites: k3s (01)
# Produces:      Prometheus + Grafana stack in monitoring namespace
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROMETHEUS_STACK_VERSION="${PROMETHEUS_STACK_VERSION:-82.9.0}"
NAMESPACE="monitoring"

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
info "Adding prometheus-community Helm repo ..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

# ---------------------------------------------------------------------------
# Step 2 — Install kube-prometheus-stack
# ---------------------------------------------------------------------------
if helm status kube-prometheus-stack -n "$NAMESPACE" &>/dev/null; then
    ok "kube-prometheus-stack is already installed"
    info "Upgrading to $PROMETHEUS_STACK_VERSION ..."
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace "$NAMESPACE" \
        --version "$PROMETHEUS_STACK_VERSION" \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
        --set grafana.sidecar.dashboards.enabled=true \
        --set grafana.sidecar.dashboards.searchNamespace=ALL \
        --wait --timeout 10m
else
    info "Installing kube-prometheus-stack $PROMETHEUS_STACK_VERSION ..."
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --version "$PROMETHEUS_STACK_VERSION" \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
        --set grafana.sidecar.dashboards.enabled=true \
        --set grafana.sidecar.dashboards.searchNamespace=ALL \
        --wait --timeout 10m
fi

# ---------------------------------------------------------------------------
# Step 3 — Verify
# ---------------------------------------------------------------------------
wait_for_pods "$NAMESPACE" "app.kubernetes.io/name=prometheus" 600
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""

# Print Grafana access info
GRAFANA_PASS=$(kubectl get secret -n "$NAMESPACE" kube-prometheus-stack-grafana \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "unknown")
info "Grafana credentials: admin / ${GRAFANA_PASS}"
info "Access Grafana: kubectl port-forward -n $NAMESPACE svc/kube-prometheus-stack-grafana 3000:80"
echo ""
ok "kube-prometheus-stack $PROMETHEUS_STACK_VERSION is running"
echo ""
info "Next step: ./scripts/07-deploy-cenotoo.sh"
