#!/usr/bin/env bash
# =============================================================================
# 22-deploy-coap-bridge.sh — Build, configure, and deploy the CoAP bridge on k3s
#
# Deploys one component:
#   • coap-bridge  (locally built — aiocoap server with inline Cassandra auth
#                   and Kafka producer)
#
# Unlike the MQTT stack, CoAP auth is built into the bridge — no sidecar needed.
# Devices connect directly: coap://<node-ip>:30683/{org}/{project}/{collection}?key=<api_key>
#
# Prerequisites: k3s (01), Cenotoo infra deployed (07), Cassandra healthy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
BRIDGE_SOURCE="$PROJECT_DIR/coap-bridge"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
BRIDGE_IMAGE="coap-bridge:${COAP_BRIDGE_TAG:-latest}"

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
b64()     { printf '%s' "$1" | base64 -w0; }

echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║    Cenotoo CoAP Bridge — Deploy to k3s   ║${RESET}"
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

kubectl get ns "$NAMESPACE" &>/dev/null \
    || fail "Namespace '$NAMESPACE' not found — run 07-deploy-cenotoo.sh first"
ok "Namespace '$NAMESPACE' exists"

kubectl get svc cenotoo-cassandra-service -n "$NAMESPACE" &>/dev/null \
    || warn "Cassandra not deployed — coap-bridge will crash-loop until Cassandra is ready"

kubectl get svc cenotoo-kafka-kafka-bootstrap -n "$NAMESPACE" &>/dev/null \
    || warn "Kafka not deployed — coap-bridge will crash-loop until Kafka is ready"

[ -f "$BRIDGE_SOURCE/Dockerfile" ] \
    || fail "coap-bridge/Dockerfile not found in $PROJECT_DIR — is this the cenotoo repo?"
ok "coap-bridge source: $BRIDGE_SOURCE"

# ── Step 2: Configure secret ─────────────────────────────────────────────────
step 2 "Configure CoAP bridge credentials"

echo -e "  ${DIM}The bridge needs the organisation UUID to validate CoAP URI segments against${RESET}"
echo -e "  ${DIM}Cassandra. This is the same ORGANIZATION_ID used by the REST API.${RESET}"
echo ""

ORGANIZATION_ID="${ORGANIZATION_ID:-}"
if [ -z "$ORGANIZATION_ID" ]; then
    echo -en "  ${BLUE}▸${RESET} Organisation UUID (ORGANIZATION_ID): "
    read -r ORGANIZATION_ID
fi
[ -n "$ORGANIZATION_ID" ] || fail "ORGANIZATION_ID must not be empty"
ok "Organisation ID: $ORGANIZATION_ID"

info "Writing K8s secret cenotoo-coap-credentials ..."
kubectl create secret generic cenotoo-coap-credentials \
    --namespace "$NAMESPACE" \
    --from-literal=organization_id="$ORGANIZATION_ID" \
    --dry-run=client -o yaml | kubectl apply -f -
ok "Secret cenotoo-coap-credentials applied"

# ── Step 3: Build image ──────────────────────────────────────────────────────
step 3 "Build Docker image"

t0=$(date +%s)
info "Building ${BRIDGE_IMAGE} from ${BRIDGE_SOURCE} ..."
echo ""
if ! docker build -t "$BRIDGE_IMAGE" "$BRIDGE_SOURCE" 2>&1 | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${RESET}"
done; then
    fail "Docker build failed for $BRIDGE_IMAGE"
fi
t1=$(date +%s)
echo ""
ok "Built ${BOLD}${BRIDGE_IMAGE}${RESET} in $((t1 - t0))s"
BRIDGE_SIZE=$(docker image inspect "$BRIDGE_IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
BRIDGE_SIZE_MB=$((BRIDGE_SIZE / 1024 / 1024))
dimtext "Image size: ${BRIDGE_SIZE_MB}MB"

# ── Step 4: Import into k3s ──────────────────────────────────────────────────
step 4 "Import into k3s"

info "docker save ${BRIDGE_IMAGE} | sudo k3s ctr images import -"
if ! docker save "$BRIDGE_IMAGE" | sudo k3s ctr images import - 2>&1 | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${RESET}"
done; then
    fail "k3s import failed for $BRIDGE_IMAGE"
fi
ok "Imported ${BRIDGE_IMAGE} into k3s containerd"

# ── Step 5: Deploy ───────────────────────────────────────────────────────────
step 5 "Deploy to k3s"

info "Applying CoAP bridge manifests ..."
kubectl apply -f "$MANIFEST_DIR/10-coap/" -n "$NAMESPACE"

info "Restarting coap-bridge to pick up new image ..."
kubectl rollout restart deployment/cenotoo-coap-bridge -n "$NAMESPACE" 2>/dev/null || true

info "Waiting for coap-bridge to be ready ..."
ELAPSED=0
TIMEOUT=120
READY=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    READY=$(kubectl get deployment cenotoo-coap-bridge -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${READY:-0}" -ge 1 ] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "${READY:-0}" -ge 1 ]; then
    ok "coap-bridge is running"
else
    warn "coap-bridge not ready after ${TIMEOUT}s — check: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=coap-bridge"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "<node-ip>")

echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}CoAP bridge deployed successfully${RESET}               │"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "Image: ${BRIDGE_IMAGE} (${BRIDGE_SIZE_MB}MB)"
printf  "  │  %-48s │\n" "Endpoint: coap://${NODE_IP}:30683"
echo -e "  │                                                  │"
echo -e "  │  ${DIM}Publish: coap://<node>:30683/{org}/{project}/{coll}${RESET} │"
echo -e "  │  ${DIM}         ?key=<write-or-master-api-key>${RESET}           │"
echo -e "  │                                                  │"
echo -e "  │  ${DIM}Health:  http://<node>:<health-port>/health${RESET}       │"
echo -e "  └──────────────────────────────────────────────────┘"
echo ""
