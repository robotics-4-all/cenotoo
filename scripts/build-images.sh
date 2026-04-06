#!/usr/bin/env bash
# =============================================================================
# build-images.sh — Build Cenotoo Docker images and load into k3s
#
# Usage:  ./scripts/build-images.sh                    # Docker build only
#         ./scripts/build-images.sh --k3s              # Build + import into k3s containerd
#         ./scripts/build-images.sh --k3s --no-cache   # Force rebuild (bust Docker layer cache)
#
# Set CENOTOO_API_DIR to override cenotoo-api source location (default: ../cenotoo-api)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FLINK_IMAGE="custom-flink-image:latest"
CASSANDRA_WRITER_IMAGE="kafka-cassandra-consumer:latest"
LIVE_CONSUMER_IMAGE="kafka-live-consumer:latest"
MQTT_AUTH_IMAGE="mqtt-auth:latest"
MQTT_BRIDGE_IMAGE="mqtt-bridge:latest"
COAP_BRIDGE_IMAGE="coap-bridge:latest"
API_IMAGE="cenotoo-api:latest"

CENOTOO_API_DIR="${CENOTOO_API_DIR:-$(cd "$PROJECT_DIR/../cenotoo-api" 2>/dev/null && pwd || echo "")}"

LOAD_K3S=false
NO_CACHE=""
for arg in "$@"; do
    case "$arg" in
        --k3s)      LOAD_K3S=true ;;
        --no-cache) NO_CACHE="--no-cache" ;;
    esac
done

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

build_and_load() {
    local context="$1" image="$2"

    info "Building $image from $context ..."
    docker build $NO_CACHE -t "$image" "$context"
    ok "Built $image"

    if [ "$LOAD_K3S" = "true" ]; then
        info "Importing $image into k3s containerd ..."
        docker save "$image" | sudo k3s ctr -n k8s.io images import -
        ok "Imported $image into k3s"
    fi
}

if ! command -v docker &>/dev/null; then
    fail "Docker is required. Install Docker first."
fi

if [ "$LOAD_K3S" = "true" ] && ! command -v k3s &>/dev/null; then
    fail "--k3s flag set but k3s is not installed"
fi

if [ -n "$NO_CACHE" ]; then
    warn "Building with --no-cache: all layers will be rebuilt from scratch"
fi

build_and_load "$PROJECT_DIR/flink" "$FLINK_IMAGE"
build_and_load "$PROJECT_DIR/kafka-to-cassandra" "$CASSANDRA_WRITER_IMAGE"
build_and_load "$PROJECT_DIR/kafka-live-consumer" "$LIVE_CONSUMER_IMAGE"
build_and_load "$PROJECT_DIR/mqtt-auth" "$MQTT_AUTH_IMAGE"
build_and_load "$PROJECT_DIR/mqtt-bridge" "$MQTT_BRIDGE_IMAGE"
build_and_load "$PROJECT_DIR/coap-bridge" "$COAP_BRIDGE_IMAGE"

if [ -n "$CENOTOO_API_DIR" ] && [ -d "$CENOTOO_API_DIR" ]; then
    build_and_load "$CENOTOO_API_DIR" "$API_IMAGE"
else
    warn "cenotoo-api source not found — skipping API image build"
    warn "Set CENOTOO_API_DIR or clone cenotoo-api next to this repo"
fi

echo ""
ok "All images built successfully"
if [ "$LOAD_K3S" = "true" ]; then
    ok "All images imported into k3s containerd"
    info "Verify: sudo k3s ctr images list | grep -E 'custom-flink|kafka-cassandra|kafka-live|mqtt-auth|mqtt-bridge|coap-bridge|cenotoo-api'"

    if kubectl get namespace cenotoo &>/dev/null; then
        info "Rolling restart of cenotoo deployments to pick up new images ..."
        kubectl rollout restart deployment \
            cenotoo-cassandra-writer \
            cenotoo-live-consumer \
            cenotoo-api \
            cenotoo-mqtt-bridge \
            cenotoo-coap-bridge \
            -n cenotoo 2>/dev/null || true
        kubectl rollout status deployment/cenotoo-api -n cenotoo --timeout=120s
        kubectl rollout status deployment/cenotoo-cassandra-writer -n cenotoo --timeout=120s
        ok "All deployments rolled out with new images"
    fi
fi
