#!/usr/bin/env bash
# =============================================================================
# run-e2e.sh — Run the SDK e2e suite against a live Cenotoo API
#
# Usage:
#   CENOTOO_BASE_URL=https://api.example.com \
#   CENOTOO_USERNAME=admin CENOTOO_PASSWORD=... ./run-e2e.sh [--cleanup-only]
#
#   # Self-signed ingress: trust the private CA for both the preflight and
#   # the SDK (conftest.py exports it as SSL_CERT_FILE for httpx).
#   CENOTOO_CA_BUNDLE=deploy/k8s/.local-ca/ca.crt \
#   CENOTOO_BASE_URL=https://api.cenotoo.local \
#   CENOTOO_USERNAME=nostradamus CENOTOO_PASSWORD=... ./run-e2e.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BASE_URL="${CENOTOO_BASE_URL:-}"
USERNAME="${CENOTOO_USERNAME:-}"
PASSWORD="${CENOTOO_PASSWORD:-}"
CA_BUNDLE="${CENOTOO_CA_BUNDLE:-}"

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

# Private CA: --cacert here, and conftest.py turns the same bundle into
# SSL_CERT_FILE so the SDK's token fetch and API calls both trust it.
if [ -n "$CA_BUNDLE" ]; then
    if [ ! -f "$CA_BUNDLE" ]; then
        echo "CENOTOO_CA_BUNDLE is not a file: $CA_BUNDLE" >&2
        exit 2
    fi
    export CENOTOO_CA_BUNDLE
    info "TLS: trusting private CA bundle $CA_BUNDLE"
else
    info "TLS: system trust store (CENOTOO_CA_BUNDLE unset)"
fi

# api_health: GET /health, verifying the ingress cert (never --insecure).
api_health() {
    if [ -n "$CA_BUNDLE" ]; then
        curl -fsS -m 5 --cacert "$CA_BUNDLE" "$BASE_URL/health"
    else
        curl -fsS -m 5 "$BASE_URL/health"
    fi
}

info "Waiting for API at $BASE_URL ..."
ready=0
for _ in $(seq 1 90); do
    if api_health >/dev/null 2>&1; then
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
