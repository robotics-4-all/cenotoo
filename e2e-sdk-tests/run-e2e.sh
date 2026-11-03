#!/usr/bin/env bash
# =============================================================================
# run-e2e.sh — Run the SDK e2e suite against a live Cenotoo API
#
# Usage:
#   CENOTOO_BASE_URL=http://172.16.63.190:30080 \
#   CENOTOO_USERNAME=admin CENOTOO_PASSWORD=... ./run-e2e.sh [--cleanup-only]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BASE_URL="${CENOTOO_BASE_URL:-}"
USERNAME="${CENOTOO_USERNAME:-}"
PASSWORD="${CENOTOO_PASSWORD:-}"

passed=0
failed=0

pass() { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info() { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }

missing=()
[ -z "$BASE_URL" ] && missing+=("CENOTOO_BASE_URL")
[ -z "$USERNAME" ] && missing+=("CENOTOO_USERNAME")
[ -z "$PASSWORD" ] && missing+=("CENOTOO_PASSWORD")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Usage: CENOTOO_BASE_URL=<url> CENOTOO_USERNAME=<user> CENOTOO_PASSWORD=<pass> $0"
    echo "Missing: ${missing[*]}"
    exit 2
fi

info "Waiting for API at $BASE_URL ..."
ready=0
for _ in $(seq 1 90); do
    if curl -fsS -m 5 "$BASE_URL/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    fail "API not healthy at $BASE_URL/health after ~180s"
    exit 1
fi
pass "API healthy at $BASE_URL"

if [ "${1:-}" = "--cleanup-only" ]; then
    info "--cleanup-only: stale e2e-* cleanup is handled by fixture teardown; nothing to do."
    exit 0
fi

info "Running pytest -m e2e ..."
if python -m pytest "$SCRIPT_DIR" -m e2e -v; then
    pass "SDK e2e suite green"
else
    fail "SDK e2e suite failed"
    exit 1
fi

echo ""
echo "e2e done: $passed passed-step(s), $failed failed-step(s)"
