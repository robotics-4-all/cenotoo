#!/usr/bin/env bash
# =============================================================================
# 01-install-k3s.sh — Install k3s (lightweight Kubernetes)
# =============================================================================
# Installs a single-node k3s cluster suitable for running Cenotoo.
# Re-running this script is safe (idempotent).
#
# Prerequisites: Linux host with systemd, curl
# Produces:      Running k3s cluster, kubectl + helm available
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
K3S_VERSION="${K3S_VERSION:-}"  # Empty = latest stable
INSTALL_HELM="${INSTALL_HELM:-true}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

wait_for_node() {
    info "Waiting for k3s node to be Ready ..."
    local retries=60
    for i in $(seq 1 "$retries"); do
        if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
            return 0
        fi
        sleep 5
    done
    fail "Node did not become Ready within $((retries * 5))s"
}

# ---------------------------------------------------------------------------
# Step 1 — Install k3s
# ---------------------------------------------------------------------------
if command -v k3s &>/dev/null && systemctl is-active --quiet k3s; then
    ok "k3s is already installed and running"
else
    info "Installing k3s ..."
    export INSTALL_K3S_VERSION="${K3S_VERSION}"
    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644
    ok "k3s installed"
fi

# ---------------------------------------------------------------------------
# Step 2 — Configure kubeconfig
# ---------------------------------------------------------------------------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if ! grep -q 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml' ~/.bashrc 2>/dev/null; then
    info "Adding KUBECONFIG to ~/.bashrc"
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
fi

# Also create the standard ~/.kube/config symlink for tools that expect it
if [ ! -e "$HOME/.kube/config" ]; then
    mkdir -p "$HOME/.kube"
    ln -sf /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
    info "Symlinked kubeconfig to ~/.kube/config"
fi

# ---------------------------------------------------------------------------
# Step 3 — Wait for node readiness
# ---------------------------------------------------------------------------
wait_for_node
ok "k3s node is Ready"

# ---------------------------------------------------------------------------
# Step 4 — Install Helm (if not present)
# ---------------------------------------------------------------------------
if [ "$INSTALL_HELM" = "true" ]; then
    if command -v helm &>/dev/null; then
        ok "Helm is already installed: $(helm version --short 2>/dev/null || echo 'unknown')"
    else
        info "Installing Helm ..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        ok "Helm installed: $(helm version --short)"
    fi
fi

# ---------------------------------------------------------------------------
# Step 5 — Verify
# ---------------------------------------------------------------------------
info "Cluster info:"
kubectl get nodes -o wide
echo ""
kubectl get sc
echo ""
ok "k3s bootstrap complete. Default StorageClass: local-path"
echo ""
info "Next step: ./scripts/02-install-cert-manager.sh"
