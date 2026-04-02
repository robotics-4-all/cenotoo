#!/usr/bin/env bash
# =============================================================================
# 08-deploy-api.sh — Build, configure, and deploy the Cenotoo API on k3s
#
# Prerequisites: k3s (01), Cenotoo infra deployed (07), cenotoo-api source
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
SECRETS_DIR="$MANIFEST_DIR/01-secrets"
API_SOURCE="${CENOTOO_API_DIR:-$(cd "$PROJECT_DIR/../cenotoo-api" 2>/dev/null && pwd || echo "")}"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
IMAGE_NAME="cenotoo-api"
IMAGE_TAG="${CENOTOO_API_TAG:-latest}"
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
step()    { echo -e "\n${BOLD}[$1/6]${RESET} $2\n"; }
dimtext() { echo -e "  ${DIM}$*${RESET}"; }
b64()     { printf '%s' "$1" | base64 -w0; }

prompt() {
    local var_name="$1" prompt_text="$2" default="$3" is_secret="${4:-false}"
    local value
    if [ "$is_secret" = "true" ]; then
        echo -en "  ${BLUE}▸${RESET} ${prompt_text} "
        [ -n "$default" ] && echo -en "${DIM}(press Enter for default)${RESET} "
        read -rs value
        echo ""
    else
        echo -en "  ${BLUE}▸${RESET} ${prompt_text} "
        [ -n "$default" ] && echo -en "${DIM}[${default}]${RESET} "
        read -r value
    fi
    value="${value:-$default}"
    eval "$var_name=\"\$value\""
}

echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║       Cenotoo API — Deploy to k3s        ║${RESET}"
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

kubectl get svc cenotoo-kafka-kafka-bootstrap -n "$NAMESPACE" &>/dev/null || warn "Kafka not deployed — API will crash-loop until infra is ready"
kubectl get svc cenotoo-cassandra -n "$NAMESPACE" &>/dev/null || warn "Cassandra not deployed — API will crash-loop until infra is ready"

[ -z "$API_SOURCE" ] || [ ! -d "$API_SOURCE" ] && fail "cenotoo-api source not found. Set CENOTOO_API_DIR or clone it next to this repo."
ok "API source: $API_SOURCE"

[ -f "$API_SOURCE/Dockerfile" ] || fail "Dockerfile not found in $API_SOURCE"
ok "Dockerfile found"

# ── Step 2: Configure JWT/API key secrets ────────────────────────────────────
step 2 "Configure secrets"

echo -e "  ${DIM}Press Enter to auto-generate secrets.${RESET}"
echo ""

prompt JWT_SECRET "JWT secret key:" "" true
if [ -z "$JWT_SECRET" ]; then
    JWT_SECRET=$(openssl rand -hex 32)
    ok "Generated random JWT secret"
fi

prompt API_KEY_SECRET "API key secret:" "" true
if [ -z "$API_KEY_SECRET" ]; then
    API_KEY_SECRET=$(openssl rand -hex 32)
    ok "Generated random API key secret"
fi

echo ""
info "Writing K8s secrets ..."

cat > "$SECRETS_DIR/api-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cenotoo-api-secrets
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: cenotoo
type: Opaque
data:
  jwt-secret-key: $(b64 "$JWT_SECRET")
  api-key-secret: $(b64 "$API_KEY_SECRET")
EOF

ok "Wrote api-secrets.yaml"

# ── Step 3: Build Docker image ───────────────────────────────────────────────
step 3 "Build Docker image"

BUILD_START=$(date +%s)
info "Building ${FULL_IMAGE} ..."
echo ""

if ! docker build -t "$FULL_IMAGE" "$API_SOURCE" 2>&1 | while IFS= read -r line; do
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

# ── Step 5: Migrate Cassandra schema ─────────────────────────────────────────
step 5 "Migrate Cassandra schema"

info "Running schema migration (safe to re-run — all statements are IF NOT EXISTS) ..."
"$SCRIPT_DIR/init-cassandra-schema.sh"

# ── Step 6: Deploy ───────────────────────────────────────────────────────────
step 6 "Deploy to k3s"

info "Applying API secrets ..."
kubectl apply -f "$SECRETS_DIR/api-secrets.yaml" -n "$NAMESPACE"

info "Applying API deployment ..."
kubectl apply -f "$MANIFEST_DIR/07-api/" -n "$NAMESPACE"

info "Restarting API pods to pick up new secrets ..."
kubectl rollout restart deployment/cenotoo-api -n "$NAMESPACE" 2>/dev/null || true

info "Waiting for API to be ready ..."
ELAPSED=0
TIMEOUT=120
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    READY=$(kubectl get deployment cenotoo-api -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${READY:-0}" -ge 1 ] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "${READY:-0}" -ge 1 ]; then
    ok "API is running"
else
    warn "API not ready after ${TIMEOUT}s — check: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=api"
fi

# ── Step 6: Done ─────────────────────────────────────────────────────────────
step 6 "Done"

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")

echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}API deployed successfully${RESET}                       │"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "Image:    ${FULL_IMAGE}"
printf  "  │  %-48s │\n" "Size:     ${IMAGE_SIZE_MB}MB"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "API:      http://${NODE_IP}:30080"
printf  "  │  %-48s │\n" "Docs:     http://${NODE_IP}:30080/docs"
echo -e "  │                                                  │"
echo -e "  │  ${DIM}Admin credentials set during schema init.${RESET}      │"
echo -e "  │  ${DIM}Login:${RESET}                                         │"
echo -e "  │  ${DIM}  curl -X POST http://${NODE_IP}:30080/api/v1/token \\${RESET}"
echo -e "  │  ${DIM}    -d 'username=<admin>&password=<pass>'${RESET}       │"
echo -e "  └──────────────────────────────────────────────────┘"
echo ""
