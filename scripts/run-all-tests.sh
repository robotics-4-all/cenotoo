#!/usr/bin/env bash
# =============================================================================
# run-all-tests.sh — Run the full Cenotoo test suite in sequence
#
# Executes every test script in order, streams live output, and prints a
# consolidated pass/fail summary at the end. A suite is marked SKIP if its
# script file does not exist.
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username  (default: admin)
#   CENOTOO_ADMIN_PASSWORD   API admin password  (required — no default)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/run-all-tests.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

SUITE_NAMES=()
SUITE_STATUS=()
SUITE_TIMES=()
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
START_TIME=$(date +%s)

ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-admin}"

fmttime() {
    local s="$1"
    [ "$s" -ge 60 ] && printf '%dm%ds' $((s / 60)) $((s % 60)) || printf '%ds' "$s"
}

run_suite() {
    local name="$1"
    local script="$2"

    if [ ! -f "$script" ]; then
        SUITE_NAMES+=("$name")
        SUITE_STATUS+=("SKIP")
        SUITE_TIMES+=("-")
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        printf '\n%b─ %-22s%b %b(script not found — skipping)%b\n' \
            "$YELLOW" "$name" "$RESET" "$DIM" "$RESET"
        return
    fi

    printf '\n%b╔═  %s  %b\n' "$CYAN$BOLD" "$name" "$RESET"
    echo -e "${DIM}    $(basename "$script") — namespace=$NAMESPACE release=$RELEASE${RESET}"
    echo ""

    local t0 t1 elapsed exit_code
    t0=$(date +%s)

    set +e
    CENOTOO_ADMIN_USERNAME="$ADMIN_USERNAME" \
    CENOTOO_ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD:-}" \
        bash "$script" "$NAMESPACE" "$RELEASE"
    exit_code=$?
    set -e

    t1=$(date +%s)
    elapsed=$((t1 - t0))

    SUITE_NAMES+=("$name")
    SUITE_TIMES+=("$(fmttime "$elapsed")")

    if [ "$exit_code" -eq 0 ]; then
        SUITE_STATUS+=("PASS")
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
        printf '\n%b╚═  %s PASSED%b  (%s)\n' "$GREEN$BOLD" "$name" "$RESET" "$(fmttime "$elapsed")"
    else
        SUITE_STATUS+=("FAIL")
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        printf '\n%b╚═  %s FAILED%b  (%s)\n' "$RED$BOLD" "$name" "$RESET" "$(fmttime "$elapsed")"
    fi
}

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}  ╔════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║     Cenotoo — Full Test Suite Runner      ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}Namespace : $NAMESPACE${RESET}"
echo -e "  ${DIM}Release   : $RELEASE${RESET}"
echo -e "  ${DIM}Admin user: $ADMIN_USERNAME${RESET}"

# ── Preflight ────────────────────────────────────────────────────────────────
if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    echo -e "\n  ${RED}✗${RESET}  CENOTOO_ADMIN_PASSWORD is not set"
    printf '\n\033[1;31mRun: CENOTOO_ADMIN_PASSWORD=<pass> %s\033[0m\n' "$0"
    exit 1
fi

if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    echo -e "\n  ${RED}✗${RESET}  Namespace '$NAMESPACE' not found"
    exit 1
fi

# ── Suite Execution ───────────────────────────────────────────────────────────
run_suite "Smoke"              "$SCRIPT_DIR/smoke-test.sh"
run_suite "Infrastructure"     "$SCRIPT_DIR/integration-test.sh"
run_suite "PostgreSQL"         "$SCRIPT_DIR/25-test-postgres.sh"
run_suite "MQTT"               "$SCRIPT_DIR/13-test-mqtt.sh"
run_suite "CoAP"               "$SCRIPT_DIR/23-test-coap.sh"
run_suite "SSE Streaming"      "$SCRIPT_DIR/14-test-sse-stream.sh"
run_suite "Device Management"  "$SCRIPT_DIR/15-test-device-management.sh"
run_suite "Schema Evolution"   "$SCRIPT_DIR/16-test-schema-evolution.sh"
run_suite "Collection Metrics" "$SCRIPT_DIR/17-test-collection-metrics.sh"
run_suite "Data Export"        "$SCRIPT_DIR/18-test-data-export.sh"
run_suite "Bulk Import"        "$SCRIPT_DIR/19-test-bulk-import.sh"
run_suite "Webhooks"           "$SCRIPT_DIR/20-test-webhooks.sh"
run_suite "Statistics"         "$SCRIPT_DIR/21-test-statistics.sh"

# ── Summary ───────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

echo ""
echo -e "${BOLD}  ┌────────────────────────────────────────┐${RESET}"
echo -e "${BOLD}  │  Results                               │${RESET}"
echo -e "${BOLD}  ├────────────────────────────────────────┤${RESET}"

for i in "${!SUITE_NAMES[@]}"; do
    name="${SUITE_NAMES[$i]}"
    status="${SUITE_STATUS[$i]}"
    time="${SUITE_TIMES[$i]}"
    if [ "$status" = "PASS" ]; then
        printf "  │  ${GREEN}✓ PASS${RESET}  %-22s %s\n" "$name" "$time"
    elif [ "$status" = "FAIL" ]; then
        printf "  │  ${RED}✗ FAIL${RESET}  %-22s %s\n" "$name" "$time"
    else
        printf "  │  ${YELLOW}─ SKIP${RESET}  %-22s %s\n" "$name" "$time"
    fi
done

echo -e "${BOLD}  └────────────────────────────────────────┘${RESET}"
echo ""

printf '  '
printf "${GREEN}${BOLD}%d passed${RESET}" "$TOTAL_PASSED"
[ "$TOTAL_FAILED"  -gt 0 ] && printf ", ${RED}${BOLD}%d failed${RESET}"  "$TOTAL_FAILED"
[ "$TOTAL_SKIPPED" -gt 0 ] && printf ", ${YELLOW}%d skipped${RESET}" "$TOTAL_SKIPPED"
printf "  ($(fmttime "$TOTAL_ELAPSED") total)\n\n"

if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "${RED}${BOLD}FULL TEST RUN FAILED${RESET}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${RESET}"
    exit 0
fi
