#!/usr/bin/env bash
# =============================================================================
# 12-deploy-mqtt-bridge.sh — Build, configure, and deploy the MQTT bridge on k3s
#
# Deploys three components:
#   • mqtt-auth         (locally built sidecar — Cassandra-backed auth for Mosquitto)
#   • Mosquitto broker  (iegomez/mosquitto-go-auth — pulled from Docker Hub)
#   • mqtt-bridge       (locally built from mqtt-bridge/ in this repo)
#
# mqtt-auth runs as a sidecar in the Mosquitto pod, validating MQTT client
# credentials and topic ACLs directly against Cassandra.
#
# Prerequisites: k3s (01), Cenotoo infra deployed (07), Cassandra healthy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
SECRETS_DIR="$MANIFEST_DIR/01-secrets"
AUTH_SOURCE="$PROJECT_DIR/mqtt-auth"
BRIDGE_SOURCE="$PROJECT_DIR/mqtt-bridge"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
AUTH_IMAGE="mqtt-auth:${MQTT_AUTH_TAG:-latest}"
BRIDGE_IMAGE="mqtt-bridge:${MQTT_BRIDGE_TAG:-latest}"

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
        [ -n "$default" ] && echo -en "${DIM}(press Enter to auto-generate)${RESET} "
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
echo -e "${CYAN}${BOLD}  ║    Cenotoo MQTT Bridge — Deploy to k3s   ║${RESET}"
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

kubectl get svc cenotoo-cassandra -n "$NAMESPACE" &>/dev/null \
    || warn "Cassandra not deployed — mqtt-auth will crash-loop until Cassandra is ready"

kubectl get svc cenotoo-kafka-kafka-bootstrap -n "$NAMESPACE" &>/dev/null \
    || warn "Kafka not deployed — mqtt-bridge will crash-loop until Kafka is ready"

[ -f "$AUTH_SOURCE/Dockerfile" ] \
    || fail "mqtt-auth/Dockerfile not found in $PROJECT_DIR — is this the cenotoo repo?"
ok "mqtt-auth source: $AUTH_SOURCE"

[ -f "$BRIDGE_SOURCE/Dockerfile" ] \
    || fail "mqtt-bridge/Dockerfile not found in $PROJECT_DIR — is this the cenotoo repo?"
ok "mqtt-bridge source: $BRIDGE_SOURCE"

# ── Step 2: Configure secrets ────────────────────────────────────────────────
step 2 "Configure MQTT bridge credentials"

echo -e "  ${DIM}The bridge service account authenticates to Mosquitto as a superuser.${RESET}"
echo -e "  ${DIM}These credentials are passed to both the mqtt-bridge pod and the mqtt-auth sidecar.${RESET}"
echo ""

prompt BRIDGE_USERNAME "Bridge username:" "cenotoo-bridge"
prompt BRIDGE_PASSWORD "Bridge password:" "" true
if [ -z "$BRIDGE_PASSWORD" ]; then
    BRIDGE_PASSWORD=$(openssl rand -hex 32)
    ok "Generated random bridge password"
fi

echo ""
info "Writing K8s secret ..."

cat > "$SECRETS_DIR/mqtt-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cenotoo-mqtt-credentials
  labels:
    app.kubernetes.io/component: mqtt-broker
    app.kubernetes.io/part-of: cenotoo
type: Opaque
data:
  username: $(b64 "$BRIDGE_USERNAME")
  password: $(b64 "$BRIDGE_PASSWORD")
EOF

ok "Wrote mqtt-credentials.yaml"

# ── Step 3: Build images ─────────────────────────────────────────────────────
step 3 "Build Docker images"

build_image() {
    local src="$1" img="$2"
    local t0 t1
    t0=$(date +%s)
    info "Building ${img} from ${src} ..."
    echo ""
    if ! docker build -t "$img" "$src" 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done; then
        fail "Docker build failed for $img"
    fi
    t1=$(date +%s)
    echo ""
    ok "Built ${BOLD}${img}${RESET} in $((t1 - t0))s"
    local sz
    sz=$(docker image inspect "$img" --format='{{.Size}}' 2>/dev/null || echo "0")
    dimtext "Image size: $((sz / 1024 / 1024))MB"
}

build_image "$AUTH_SOURCE"   "$AUTH_IMAGE"
build_image "$BRIDGE_SOURCE" "$BRIDGE_IMAGE"

AUTH_SIZE=$(docker image inspect "$AUTH_IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
AUTH_SIZE_MB=$((AUTH_SIZE / 1024 / 1024))
BRIDGE_SIZE=$(docker image inspect "$BRIDGE_IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
BRIDGE_SIZE_MB=$((BRIDGE_SIZE / 1024 / 1024))

# ── Step 4: Import into k3s ──────────────────────────────────────────────────
step 4 "Import into k3s"

import_image() {
    local img="$1"
    info "docker save ${img} | sudo k3s ctr images import -"
    if ! docker save "$img" | sudo k3s ctr images import - 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done; then
        fail "k3s import failed for $img"
    fi
    ok "Imported ${img} into k3s containerd"
}

import_image "$AUTH_IMAGE"
import_image "$BRIDGE_IMAGE"
dimtext "Note: mosquitto-go-auth is pulled from Docker Hub at pod start — no import needed."

# ── Step 5: Deploy ───────────────────────────────────────────────────────────
step 5 "Deploy to k3s"

info "Applying MQTT credentials secret ..."
kubectl apply -f "$SECRETS_DIR/mqtt-credentials.yaml" -n "$NAMESPACE"

info "Applying MQTT manifests (mqtt-auth sidecar + mosquitto + mqtt-bridge) ..."
kubectl apply -f "$MANIFEST_DIR/09-mqtt/" -n "$NAMESPACE"

info "Restarting mqtt-bridge to pick up new image and credentials ..."
kubectl rollout restart deployment/cenotoo-mqtt-bridge -n "$NAMESPACE" 2>/dev/null || true

info "Restarting mosquitto pod to pick up new sidecar image ..."
kubectl rollout restart statefulset/cenotoo-mosquitto -n "$NAMESPACE" 2>/dev/null || true

# ── Step 6: Wait ─────────────────────────────────────────────────────────────
step 6 "Wait for readiness"

info "Waiting for mqtt-bridge to be ready ..."
ELAPSED=0
TIMEOUT=120
READY=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    READY=$(kubectl get deployment cenotoo-mqtt-bridge -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${READY:-0}" -ge 1 ] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "${READY:-0}" -ge 1 ]; then
    ok "mqtt-bridge is running"
else
    warn "mqtt-bridge not ready after ${TIMEOUT}s — check: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=mqtt-bridge"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "<node-ip>")

echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}MQTT stack deployed successfully${RESET}                │"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "mqtt-auth:   ${AUTH_IMAGE} (${AUTH_SIZE_MB}MB)"
printf  "  │  %-48s │\n" "mqtt-bridge: ${BRIDGE_IMAGE} (${BRIDGE_SIZE_MB}MB)"
printf  "  │  %-48s │\n" "Username:    ${BRIDGE_USERNAME}"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "Broker: cenotoo-mosquitto:1883 (cluster-internal)"
echo -e "  │                                                  │"
echo -e "  │  ${DIM}To expose MQTT externally, add a NodePort or${RESET}   │"
echo -e "  │  ${DIM}LoadBalancer to mosquitto-service.yaml.${RESET}         │"
echo -e "  │                                                  │"
echo -e "  │  ${DIM}Device auth: username=<project-uuid>${RESET}           │"
echo -e "  │  ${DIM}             password=<write/master API key>${RESET}    │"
echo -e "  └──────────────────────────────────────────────────┘"
echo ""
