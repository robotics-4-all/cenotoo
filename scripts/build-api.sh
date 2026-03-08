#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
API_SOURCE="${CENOTOO_API_DIR:-$(cd "$PROJECT_DIR/../cenotoo-api" 2>/dev/null && pwd || echo "")}"

IMAGE_NAME="${CENOTOO_API_IMAGE:-cenotoo-api}"
IMAGE_TAG="${CENOTOO_API_TAG:-latest}"
REGISTRY="${CENOTOO_API_REGISTRY:-}"

# --- Colors & Formatting ---
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

banner() {
    echo ""
    echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}  ║          Cenotoo API — Build Tool         ║${RESET}"
    echo -e "${CYAN}${BOLD}  ╚═══════════════════════════════════════════╝${RESET}"
    echo ""
}

info()    { echo -e "  ${BLUE}▸${RESET} $*"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}[$1/$TOTAL_STEPS]${RESET} $2\n"; }
dimtext() { echo -e "  ${DIM}$*${RESET}"; }

usage() {
    echo -e "${BOLD}Usage:${RESET}  $0 [options]"
    echo ""
    echo -e "${BOLD}Options:${RESET}"
    echo "  --tag TAG         Image tag (default: latest)"
    echo "  --registry REG    Registry prefix (e.g. ghcr.io/robotics-4-all)"
    echo "  --push            Push image to registry after build"
    echo "  --k3s             Import image into k3s containerd"
    echo "  --test            Run tests before building"
    echo "  --no-cache        Build without Docker layer cache"
    echo "  --help            Show this help"
    echo ""
    echo -e "${BOLD}Environment:${RESET}"
    echo "  CENOTOO_API_DIR       Path to cenotoo-api source (default: ../cenotoo-api)"
    echo "  CENOTOO_API_IMAGE     Image name (default: cenotoo-api)"
    echo "  CENOTOO_API_TAG       Image tag (default: latest)"
    echo "  CENOTOO_API_REGISTRY  Registry prefix"
    echo ""
    echo -e "${BOLD}Examples:${RESET}"
    echo "  $0                                    # Build cenotoo-api:latest"
    echo "  $0 --tag v1.2.0                       # Build cenotoo-api:v1.2.0"
    echo "  $0 --tag v1.2.0 --push                # Build + push to registry"
    echo "  $0 --k3s                              # Build + import into k3s"
    echo "  $0 --test --tag v1.2.0 --push         # Test + build + push"
    exit 0
}

# --- Parse Arguments ---
DO_PUSH=false
DO_K3S=false
DO_TEST=false
NO_CACHE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)       IMAGE_TAG="$2"; shift 2 ;;
        --registry)  REGISTRY="$2"; shift 2 ;;
        --push)      DO_PUSH=true; shift ;;
        --k3s)       DO_K3S=true; shift ;;
        --test)      DO_TEST=true; shift ;;
        --no-cache)  NO_CACHE="--no-cache"; shift ;;
        --help|-h)   usage ;;
        *)           fail "Unknown option: $1. Use --help for usage." ;;
    esac
done

if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
    FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
fi

# --- Calculate Steps ---
TOTAL_STEPS=3
[ "$DO_TEST" = "true" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$DO_PUSH" = "true" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "$DO_K3S" = "true" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
CURRENT_STEP=0
next_step() { CURRENT_STEP=$((CURRENT_STEP + 1)); }

# --- Start ---
banner

echo -e "  ${BOLD}Image:${RESET}    ${FULL_IMAGE}"
echo -e "  ${BOLD}Source:${RESET}   ${API_SOURCE}"
[ "$DO_TEST" = "true" ]  && echo -e "  ${BOLD}Test:${RESET}     yes"
[ "$DO_PUSH" = "true" ]  && echo -e "  ${BOLD}Push:${RESET}     yes"
[ "$DO_K3S" = "true" ]   && echo -e "  ${BOLD}k3s:${RESET}      yes"
[ -n "$NO_CACHE" ]       && echo -e "  ${BOLD}Cache:${RESET}    disabled"

# ── Step: Preflight ──────────────────────────────────────────────────────────
next_step
step "$CURRENT_STEP" "Preflight checks"

if ! command -v docker &>/dev/null; then
    fail "Docker is not installed"
fi
ok "Docker found: $(docker --version | head -1)"

if [ -z "$API_SOURCE" ] || [ ! -d "$API_SOURCE" ]; then
    fail "cenotoo-api source not found. Set CENOTOO_API_DIR or clone it next to this repo."
fi
ok "API source: $API_SOURCE"

if [ ! -f "$API_SOURCE/Dockerfile" ]; then
    fail "Dockerfile not found in $API_SOURCE"
fi
ok "Dockerfile found"

if [ ! -f "$API_SOURCE/requirements.txt" ]; then
    fail "requirements.txt not found"
fi
ok "requirements.txt found"

if [ "$DO_K3S" = "true" ]; then
    if ! command -v k3s &>/dev/null; then
        fail "--k3s flag set but k3s is not installed"
    fi
    ok "k3s found"
fi

if [ "$DO_PUSH" = "true" ] && [ -z "$REGISTRY" ]; then
    fail "--push requires --registry (e.g. --registry ghcr.io/robotics-4-all)"
fi

# ── Step: Test (optional) ────────────────────────────────────────────────────
if [ "$DO_TEST" = "true" ]; then
    next_step
    step "$CURRENT_STEP" "Running tests"

    info "Lint check ..."
    if ! ruff check "$API_SOURCE" --quiet 2>/dev/null; then
        fail "Lint failed. Fix issues before building."
    fi
    ok "Lint passed"

    info "Test suite ..."
    if ! pytest "$API_SOURCE/tests/" -q --tb=short 2>&1 | tail -3; then
        fail "Tests failed. Fix issues before building."
    fi
    ok "All tests passed"
fi

# ── Step: Build ──────────────────────────────────────────────────────────────
next_step
step "$CURRENT_STEP" "Building Docker image"

BUILD_START=$(date +%s)
info "docker build ${NO_CACHE} -t ${FULL_IMAGE} ${API_SOURCE}"
echo ""

if ! docker build $NO_CACHE -t "$FULL_IMAGE" "$API_SOURCE" 2>&1 | while IFS= read -r line; do
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

# ── Step: Import to k3s (optional) ───────────────────────────────────────────
if [ "$DO_K3S" = "true" ]; then
    next_step
    step "$CURRENT_STEP" "Importing into k3s"

    info "docker save ${FULL_IMAGE} | sudo k3s ctr images import -"
    if ! docker save "$FULL_IMAGE" | sudo k3s ctr images import - 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done; then
        fail "k3s import failed"
    fi
    ok "Imported into k3s containerd"
    dimtext "Verify: sudo k3s ctr images list | grep cenotoo-api"
fi

# ── Step: Push (optional) ────────────────────────────────────────────────────
if [ "$DO_PUSH" = "true" ]; then
    next_step
    step "$CURRENT_STEP" "Pushing to registry"

    info "docker push ${FULL_IMAGE}"
    if ! docker push "$FULL_IMAGE" 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done; then
        fail "Push failed"
    fi
    ok "Pushed to ${REGISTRY}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
next_step
step "$CURRENT_STEP" "Done"

echo -e "  ┌──────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}Build complete${RESET}                              │"
echo -e "  │                                              │"
printf  "  │  %-44s │\n" "Image:  ${FULL_IMAGE}"
printf  "  │  %-44s │\n" "Size:   ${IMAGE_SIZE_MB}MB"
printf  "  │  %-44s │\n" "Time:   ${BUILD_DURATION}s"
echo -e "  │                                              │"
if [ "$DO_K3S" = "true" ]; then
    echo -e "  │  ${GREEN}✓${RESET} Imported into k3s                         │"
fi
if [ "$DO_PUSH" = "true" ]; then
    echo -e "  │  ${GREEN}✓${RESET} Pushed to registry                        │"
fi
echo -e "  └──────────────────────────────────────────────┘"
echo ""
