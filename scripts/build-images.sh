#!/usr/bin/env bash
# =============================================================================
# build-images.sh — Build Cenotoo Docker images and load into k3s
#
# Usage:  ./scripts/build-images.sh          # Docker build only
#         ./scripts/build-images.sh --k3s    # Build + import into k3s containerd
#
# Set CENOTOO_API_DIR to override cenotoo-api source location (default: ../cenotoo-api)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FLINK_IMAGE="custom-flink-image:latest"
CASSANDRA_WRITER_IMAGE="kafka-cassandra-consumer:latest"
LIVE_CONSUMER_IMAGE="kafka-live-consumer:latest"
API_IMAGE="cenotoo-api:latest"

CENOTOO_API_DIR="${CENOTOO_API_DIR:-$(cd "$PROJECT_DIR/../cenotoo-api" 2>/dev/null && pwd || echo "")}"

LOAD_K3S=false
if [ "${1:-}" = "--k3s" ]; then
    LOAD_K3S=true
fi

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

build_and_load() {
    local context="$1" image="$2"

    info "Building $image from $context ..."
    docker build -t "$image" "$context"
    ok "Built $image"

    if [ "$LOAD_K3S" = "true" ]; then
        info "Importing $image into k3s containerd ..."
        docker save "$image" | sudo k3s ctr images import -
        ok "Imported $image into k3s"
    fi
}

if ! command -v docker &>/dev/null; then
    fail "Docker is required. Install Docker first."
fi

if [ "$LOAD_K3S" = "true" ] && ! command -v k3s &>/dev/null; then
    fail "--k3s flag set but k3s is not installed"
fi

build_and_load "$PROJECT_DIR/flink" "$FLINK_IMAGE"
build_and_load "$PROJECT_DIR/kafka-to-cassandra" "$CASSANDRA_WRITER_IMAGE"
build_and_load "$PROJECT_DIR/kafka-live-consumer" "$LIVE_CONSUMER_IMAGE"

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
    info "Verify: sudo k3s ctr images list | grep -E 'custom-flink|kafka-cassandra|kafka-live|cenotoo-api'"
fi
