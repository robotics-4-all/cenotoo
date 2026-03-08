#!/usr/bin/env bash
# =============================================================================
# 09-expose-api.sh — Expose the Cenotoo API to the public internet
#
# Guides you through setting up Ingress + TLS for the API service.
# Prerequisites: k3s (01), cert-manager (02), API deployed (08)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

info()    { echo -e "  ${BLUE}▸${RESET} $*"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}[$1/$TOTAL_STEPS]${RESET} $2\n"; }
dimtext() { echo -e "  ${DIM}$*${RESET}"; }

prompt() {
    local var_name="$1" prompt_text="$2" default="$3"
    local value
    echo -en "  ${BLUE}▸${RESET} ${prompt_text} "
    [ -n "$default" ] && echo -en "${DIM}[${default}]${RESET} "
    read -r value
    value="${value:-$default}"
    eval "$var_name=\"\$value\""
}

prompt_choice() {
    local var_name="$1" prompt_text="$2"
    shift 2
    local options=("$@")
    echo -e "  ${BLUE}▸${RESET} ${prompt_text}"
    for i in "${!options[@]}"; do
        echo -e "    ${BOLD}$((i+1)))${RESET} ${options[$i]}"
    done
    local choice
    while true; do
        echo -en "    ${DIM}Choice:${RESET} "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            eval "$var_name=\"\$choice\""
            return
        fi
        warn "Enter a number between 1 and ${#options[@]}"
    done
}

echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║     Cenotoo API — Expose to Public       ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚═══════════════════════════════════════════╝${RESET}"
echo ""

TOTAL_STEPS=4

# ── Step 1: Preflight ────────────────────────────────────────────────────────
step 1 "Preflight checks"

command -v kubectl &>/dev/null || fail "kubectl is not installed"
ok "kubectl found"

kubectl get ns "$NAMESPACE" &>/dev/null || fail "Namespace '$NAMESPACE' not found — deploy Cenotoo first"
ok "Namespace exists"

kubectl get deployment cenotoo-api -n "$NAMESPACE" &>/dev/null || fail "API not deployed — run 08-deploy-api.sh first"
ok "API deployment found"

if kubectl get crd certificates.cert-manager.io &>/dev/null; then
    HAS_CERT_MANAGER=true
    ok "cert-manager available (TLS supported)"
else
    HAS_CERT_MANAGER=false
    warn "cert-manager not found — TLS will not be available"
fi

INGRESS_CLASS=$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$INGRESS_CLASS" ]; then
    ok "Ingress controller found: $INGRESS_CLASS"
else
    warn "No ingress controller detected"
    dimtext "k3s ships with Traefik by default — it may not be installed yet"
fi

# ── Step 2: Configure ────────────────────────────────────────────────────────
step 2 "Configure exposure method"

prompt_choice EXPOSE_METHOD "How do you want to expose the API?" \
    "Domain + TLS (recommended for production)" \
    "Domain without TLS (HTTP only)" \
    "IP only — NodePort on port 30080 (no changes needed)"

if [ "$EXPOSE_METHOD" = "3" ]; then
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
    echo ""
    ok "API is already accessible at:"
    echo ""
    echo -e "    ${BOLD}http://${NODE_IP}:30080${RESET}"
    echo -e "    ${BOLD}http://${NODE_IP}:30080/docs${RESET}"
    echo ""
    dimtext "No changes were made."
    dimtext "For public access, make sure port 30080 is open in your firewall."
    exit 0
fi

prompt DOMAIN "Domain name:" "api.cenotoo.example.com"

if [ -z "$DOMAIN" ]; then
    fail "Domain name is required for Ingress"
fi

ENABLE_TLS=false
TLS_EMAIL=""
if [ "$EXPOSE_METHOD" = "1" ]; then
    if [ "$HAS_CERT_MANAGER" = "false" ]; then
        warn "TLS requested but cert-manager is not installed"
        warn "Run: sudo ./scripts/02-install-cert-manager.sh"
        fail "Install cert-manager first, then re-run this script"
    fi
    ENABLE_TLS=true
    prompt TLS_EMAIL "Email for Let's Encrypt:" ""
    while [ -z "$TLS_EMAIL" ]; do
        warn "Email is required for Let's Encrypt certificate issuance"
        prompt TLS_EMAIL "Email for Let's Encrypt:" ""
    done
fi

INGRESS_CLASS="${INGRESS_CLASS:-traefik}"

echo ""
echo -e "  ${BOLD}Summary:${RESET}"
echo -e "    Domain:     ${BOLD}${DOMAIN}${RESET}"
echo -e "    TLS:        ${BOLD}$([ "$ENABLE_TLS" = "true" ] && echo "Yes (Let's Encrypt)" || echo "No")${RESET}"
echo -e "    Ingress:    ${BOLD}${INGRESS_CLASS}${RESET}"
[ "$ENABLE_TLS" = "true" ] && echo -e "    Email:      ${BOLD}${TLS_EMAIL}${RESET}"
echo ""

prompt CONFIRM "Proceed? (y/n):" "y"
[ "$CONFIRM" != "y" ] && { echo "  Aborted."; exit 0; }

# ── Step 3: Generate and apply manifests ─────────────────────────────────────
step 3 "Apply manifests"

mkdir -p "$MANIFEST_DIR/07-api"

if [ "$ENABLE_TLS" = "true" ]; then
    info "Creating ClusterIssuer for Let's Encrypt ..."

    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cenotoo-letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${TLS_EMAIL}
    privateKeySecretRef:
      name: cenotoo-letsencrypt-key
    solvers:
      - http01:
          ingress:
            class: ${INGRESS_CLASS}
EOF
    ok "ClusterIssuer created"
fi

info "Creating Ingress ..."

if [ "$ENABLE_TLS" = "true" ]; then
    cat > "$MANIFEST_DIR/07-api/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cenotoo-api
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: cenotoo
  annotations:
    cert-manager.io/cluster-issuer: cenotoo-letsencrypt
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: cenotoo-api-tls
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cenotoo-api
                port:
                  name: http
EOF
else
    cat > "$MANIFEST_DIR/07-api/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cenotoo-api
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: cenotoo
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cenotoo-api
                port:
                  name: http
EOF
fi

kubectl apply -f "$MANIFEST_DIR/07-api/ingress.yaml" -n "$NAMESPACE"
ok "Ingress created"

if [ "$ENABLE_TLS" = "true" ]; then
    info "Waiting for TLS certificate ..."
    ELAPSED=0
    TIMEOUT=120
    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
        CERT_READY=$(kubectl get certificate cenotoo-api-tls -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$CERT_READY" = "True" ]; then
            ok "TLS certificate issued"
            break
        fi
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    if [ "$CERT_READY" != "True" ]; then
        warn "Certificate not ready after ${TIMEOUT}s — it may take a few minutes"
        dimtext "Check: kubectl describe certificate cenotoo-api-tls -n $NAMESPACE"
    fi
fi

# ── Step 4: Done ─────────────────────────────────────────────────────────────
step 4 "Done"

PROTOCOL="http"
[ "$ENABLE_TLS" = "true" ] && PROTOCOL="https"

echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}API exposed successfully${RESET}                        │"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "API:   ${PROTOCOL}://${DOMAIN}"
printf  "  │  %-48s │\n" "Docs:  ${PROTOCOL}://${DOMAIN}/docs"
echo -e "  │                                                  │"

if [ "$ENABLE_TLS" = "true" ]; then
    echo -e "  │  ${GREEN}✓${RESET} TLS enabled (Let's Encrypt)                  │"
else
    echo -e "  │  ${YELLOW}⚠${RESET} No TLS — traffic is unencrypted              │"
fi

echo -e "  └──────────────────────────────────────────────────┘"
echo ""

echo -e "  ${BOLD}DNS Setup:${RESET}"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
echo -e "  ${DIM}Point your domain to the node's public IP:${RESET}"
echo -e "  ${DIM}  ${DOMAIN}  →  A record  →  ${NODE_IP}${RESET}"
echo ""

if [ "$ENABLE_TLS" = "true" ]; then
    echo -e "  ${DIM}Certificate will auto-renew via cert-manager.${RESET}"
    echo -e "  ${DIM}Check status: kubectl get certificate -n $NAMESPACE${RESET}"
fi
echo ""
