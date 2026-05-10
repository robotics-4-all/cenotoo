#!/usr/bin/env bash
# =============================================================================
# 10-deploy-dashboard.sh — Build and deploy the Cenotoo Dashboard on k3s
#
# The dashboard is a static SPA (React + Vite). The API URL is baked into
# the bundle at build time via VITE_API_URL — this script writes the correct
# value to .env.production in the dashboard source before building the image.
#
# Prerequisites: k3s (01), Cenotoo infra deployed (07), cenotoo-dashboard source
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
DASHBOARD_SOURCE="${CENOTOO_DASHBOARD_DIR:-$(cd "$PROJECT_DIR/../cenotoo-dashboard" 2>/dev/null && pwd || echo "")}"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
IMAGE_NAME="cenotoo-dashboard"
IMAGE_TAG="${CENOTOO_DASHBOARD_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

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
step()    { echo -e "\n${BOLD}[$1/5]${RESET} $2\n"; }
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

echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║   Cenotoo Dashboard — Deploy to k3s      ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚═══════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Preflight ────────────────────────────────────────────────────────
step 1 "Preflight checks"

command -v docker &>/dev/null || fail "Docker is not installed"
ok "Docker found"

command -v kubectl &>/dev/null || fail "kubectl is not installed"
ok "kubectl found"

command -v k3s &>/dev/null || fail "k3s is not installed"
ok "k3s found"

kubectl get ns "$NAMESPACE" &>/dev/null || fail "Namespace '$NAMESPACE' not found — run 07-deploy-cenotoo.sh first"
ok "Namespace '$NAMESPACE' exists"

kubectl get svc cenotoo-api -n "$NAMESPACE" &>/dev/null \
    || warn "cenotoo-api service not found — dashboard will show connection errors until API is deployed"

[ -z "$DASHBOARD_SOURCE" ] || [ ! -d "$DASHBOARD_SOURCE" ] \
    && fail "cenotoo-dashboard source not found. Set CENOTOO_DASHBOARD_DIR or clone it next to this repo."
ok "Dashboard source: $DASHBOARD_SOURCE"

[ -f "$DASHBOARD_SOURCE/Dockerfile" ] || fail "Dockerfile not found in $DASHBOARD_SOURCE"
ok "Dockerfile found"

[ -f "$DASHBOARD_SOURCE/package.json" ] || fail "package.json not found in $DASHBOARD_SOURCE"
ok "package.json found"

# ── Step 2: Configure API endpoint ───────────────────────────────────────────
step 2 "Configure API endpoint"

echo -e "  ${DIM}The API URL is baked into the SPA bundle at build time.${RESET}"
echo -e "  ${DIM}It must be reachable from the browser — use the node IP, not a cluster-internal address.${RESET}"
echo ""

NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "")

if [ -n "$NODE_IP" ]; then
    DEFAULT_API_URL="http://${NODE_IP}:30080"
    ok "Detected node IP: ${NODE_IP}"
else
    DEFAULT_API_URL="http://192.168.1.29:30080"
    warn "Could not detect node IP — using fallback default"
fi

prompt API_URL "API URL (VITE_API_URL):" "$DEFAULT_API_URL"

echo ""
info "Writing VITE_API_URL=${API_URL} to .env.production ..."
printf 'VITE_API_URL=%s\n' "$API_URL" > "$DASHBOARD_SOURCE/.env.production"
ok "Wrote .env.production"

# ── Step 3: Build Docker image ───────────────────────────────────────────────
step 3 "Build Docker image"

BUILD_START=$(date +%s)
info "Building ${FULL_IMAGE} from ${DASHBOARD_SOURCE} ..."
echo ""

if ! docker build -t "$FULL_IMAGE" "$DASHBOARD_SOURCE" 2>&1 | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${RESET}"
done; then
    fail "Docker build failed"
fi

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

echo ""
ok "Built ${BOLD}${FULL_IMAGE}${RESET} in ${BUILD_DURATION}s"

IMAGE_SIZE=$(docker image inspect "$FULL_IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
IMAGE_SIZE_MB=$((IMAGE_SIZE / 1024 / 1024))
dimtext "Image size: ${IMAGE_SIZE_MB}MB"

# ── Step 4: Import into k3s ──────────────────────────────────────────────────
step 4 "Import into k3s"

info "docker save ${FULL_IMAGE} | sudo k3s ctr images import -"
if ! docker save "$FULL_IMAGE" | sudo k3s ctr images import - 2>&1 | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${RESET}"
done; then
    fail "k3s import failed"
fi
ok "Imported into k3s containerd"

# ── Step 5: Deploy ───────────────────────────────────────────────────────────
step 5 "Deploy to k3s"

info "Applying dashboard manifests ..."
kubectl apply -f "$MANIFEST_DIR/08-dashboard/" -n "$NAMESPACE"

info "Restarting dashboard pods to pick up new image ..."
kubectl rollout restart deployment/cenotoo-dashboard -n "$NAMESPACE" 2>/dev/null || true

info "Waiting for dashboard to be ready ..."
ELAPSED=0
TIMEOUT=60
READY=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    READY=$(kubectl get deployment cenotoo-dashboard -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${READY:-0}" -ge 1 ] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "${READY:-0}" -ge 1 ]; then
    ok "Dashboard is running"
else
    warn "Dashboard not ready after ${TIMEOUT}s — check: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=dashboard"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
NODE_IP_FINAL=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "<node-ip>")

echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}Dashboard deployed successfully${RESET}                 │"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "Image:     ${FULL_IMAGE}"
printf  "  │  %-48s │\n" "Size:      ${IMAGE_SIZE_MB}MB"
printf  "  │  %-48s │\n" "API URL:   ${API_URL}"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "Dashboard: http://${NODE_IP_FINAL}:30081"
echo -e "  └──────────────────────────────────────────────────┘"
echo ""
