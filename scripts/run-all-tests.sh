#!/usr/bin/env bash
# =============================================================================
# run-all-tests.sh — Cenotoo test suite runner (interactive or non-interactive)
#
# Modes (auto-detected, override with flags):
#   - Interactive   : pick suites via menu (default when run from a TTY)
#   - --all         : run every suite (default for non-TTY, e.g. CI)
#   - --only LIST   : run a comma-separated subset (e.g. --only "Smoke,MQTT")
#   - --list        : print suite names and exit
#
# Credentials:
#   CENOTOO_ADMIN_USERNAME   API admin username  (default: admin)
#   CENOTOO_ADMIN_PASSWORD   API admin password
#                            Auto-discovered from .secrets/credentials.txt
#                            if not exported. Required in some form.
#
# Usage:
#   ./scripts/run-all-tests.sh                       # interactive picker
#   ./scripts/run-all-tests.sh --all                 # run everything
#   ./scripts/run-all-tests.sh --only "Smoke,MQTT"   # run a subset
#   ./scripts/run-all-tests.sh --list                # show suite names
#   ./scripts/run-all-tests.sh [NAMESPACE] [RELEASE] # custom ns/release
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared UI library if present (info/ok/warn/banner/dimtext).
# Falls back to inline equivalents below so the script still works on older
# checkouts where lib/ui.sh wasn't yet introduced.
if [ -f "$SCRIPT_DIR/lib/ui.sh" ]; then
    # shellcheck source=lib/ui.sh
    source "$SCRIPT_DIR/lib/ui.sh"
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
NAMESPACE="cenotoo"
RELEASE="cenotoo"
MODE=""
ONLY_LIST=""

# ── Suite registry ──────────────────────────────────────────────────────────
# Display name | script filename. Add new suites here only — both the picker
# menu and the runner iterate this single list.
ALL_SUITES=(
    "Smoke|smoke-test.sh"
    "Infrastructure|integration-test.sh"
    "PostgreSQL|25-test-postgres.sh"
    "MQTT|13-test-mqtt.sh"
    "CoAP|23-test-coap.sh"
    "SSE Streaming|14-test-sse-stream.sh"
    "Device Management|15-test-device-management.sh"
    "Schema Evolution|16-test-schema-evolution.sh"
    "Collection Metrics|17-test-collection-metrics.sh"
    "Data Export|18-test-data-export.sh"
    "Bulk Import|19-test-bulk-import.sh"
    "Webhooks|20-test-webhooks.sh"
    "Statistics|21-test-statistics.sh"
)

# ── Arg parsing ──────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: run-all-tests.sh [OPTIONS] [NAMESPACE] [RELEASE]

Options:
  --all                 Run every suite (no menu).
  --only "A,B,C"        Run only the listed suites (comma-separated names).
  --list                Print suite names and exit.
  -h, --help            Show this help.

Positional:
  NAMESPACE             Kubernetes namespace (default: cenotoo)
  RELEASE               Release name           (default: cenotoo)

Credentials:
  CENOTOO_ADMIN_USERNAME    Default: admin
  CENOTOO_ADMIN_PASSWORD    Auto-discovered from .secrets/credentials.txt
                            when not exported.
USAGE
}

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --all)    MODE="all"; shift ;;
        --only)   MODE="only"; ONLY_LIST="${2:-}"; shift 2 ;;
        --list)   MODE="list"; shift ;;
        -h|--help) usage; exit 0 ;;
        --*)      echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)        POSITIONAL+=("$1"); shift ;;
    esac
done
[ "${#POSITIONAL[@]}" -ge 1 ] && NAMESPACE="${POSITIONAL[0]}"
[ "${#POSITIONAL[@]}" -ge 2 ] && RELEASE="${POSITIONAL[1]}"

# Auto-mode: TTY → interactive, no TTY → all.
if [ -z "$MODE" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        MODE="interactive"
    else
        MODE="all"
    fi
fi

# ── --list short-circuit ─────────────────────────────────────────────────────
if [ "$MODE" = "list" ]; then
    for entry in "${ALL_SUITES[@]}"; do
        echo "${entry%%|*}"
    done
    exit 0
fi

# ── Fallback UI helpers (no-op when lib/ui.sh sourced above) ─────────────────
if ! declare -F info >/dev/null 2>&1; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[1;34m'; CYAN=$'\033[1;36m'
    info()    { echo -e "  ${BLUE}▸${RESET} $*"; }
    ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
    warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
    fail()    { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }
    dimtext() { echo -e "  ${DIM}$*${RESET}"; }
    banner()  { echo; echo -e "  ${CYAN}${BOLD}╔══ $* ══╗${RESET}"; echo; }
fi

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# ── Banner ───────────────────────────────────────────────────────────────────
banner "Cenotoo — Test Suite Runner"
dimtext "Namespace : $NAMESPACE"
dimtext "Release   : $RELEASE"

# ── Credential auto-discovery ────────────────────────────────────────────────
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-admin}"

if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    # Auto-discover from install.sh's generated credentials file. The runner
    # is normally invoked right after install on the same host, so this saves
    # users from having to re-export the password every session.
    CRED_FILE="$PROJECT_DIR/.secrets/credentials.txt"
    if [ -r "$CRED_FILE" ]; then
        DISCOVERED="$(grep -E '^ADMIN_PASSWORD=' "$CRED_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
        if [ -n "$DISCOVERED" ]; then
            export CENOTOO_ADMIN_PASSWORD="$DISCOVERED"
            ok "Discovered admin password from .secrets/credentials.txt"
        fi
    fi
fi

if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    warn "CENOTOO_ADMIN_PASSWORD is not set and could not be auto-discovered."
    warn "Export it manually or place it in .secrets/credentials.txt:"
    warn "  CENOTOO_ADMIN_PASSWORD=<password> $0"
    fail "Cannot continue without admin credentials."
fi

dimtext "Admin user: $ADMIN_USERNAME"
echo

# ── Namespace preflight ─────────────────────────────────────────────────────
if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    fail "Namespace '$NAMESPACE' not found"
fi

# ── Suite selection ─────────────────────────────────────────────────────────
SELECTED=()

select_all() {
    SELECTED=("${ALL_SUITES[@]}")
}

select_by_only() {
    # Comma-separated names → exact match against ALL_SUITES.
    local IFS=','
    local wanted_csv="$1"
    read -ra wanted <<< "$wanted_csv"
    for name in "${wanted[@]}"; do
        # Trim whitespace
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        local matched=0
        for entry in "${ALL_SUITES[@]}"; do
            if [ "${entry%%|*}" = "$name" ]; then
                SELECTED+=("$entry")
                matched=1
                break
            fi
        done
        [ "$matched" -eq 0 ] && fail "Unknown suite: '$name' (use --list to see valid names)"
    done
}

select_interactive() {
    # Multi-select picker. User enters indices (e.g. "1 3 5"), "a" for all,
    # or empty/Enter to default to all suites.
    echo
    info "Select suites to run (space-separated indices, 'a' for all, Enter for all):"
    echo
    local i=1
    for entry in "${ALL_SUITES[@]}"; do
        local name="${entry%%|*}"
        printf '    %2d) %s\n' "$i" "$name"
        i=$((i + 1))
    done
    echo
    local choice
    read -r -p "  Choice: " choice
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"

    if [ -z "$choice" ] || [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
        select_all
        return
    fi

    local total="${#ALL_SUITES[@]}"
    for tok in $choice; do
        if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
            fail "Invalid input '$tok' (must be a number, 'a', or empty)"
        fi
        if [ "$tok" -lt 1 ] || [ "$tok" -gt "$total" ]; then
            fail "Index out of range: $tok (valid 1..$total)"
        fi
        SELECTED+=("${ALL_SUITES[$((tok - 1))]}")
    done

    [ "${#SELECTED[@]}" -eq 0 ] && fail "No suites selected"
}

case "$MODE" in
    all)         select_all ;;
    only)        [ -z "$ONLY_LIST" ] && fail "--only requires a comma-separated list"
                 select_by_only "$ONLY_LIST" ;;
    interactive) select_interactive ;;
    *)           fail "Unknown mode: $MODE" ;;
esac

echo
info "Will run ${#SELECTED[@]} suite(s):"
for entry in "${SELECTED[@]}"; do
    dimtext "  • ${entry%%|*}"
done
echo

# ── Execution ───────────────────────────────────────────────────────────────
SUITE_NAMES=()
SUITE_STATUS=()
SUITE_TIMES=()
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
START_TIME=$(date +%s)

# ANSI codes used inside run_suite (defined here so they exist whether or not
# lib/ui.sh was sourced — ui.sh keeps some of these as locals in functions).
[ -z "${BOLD:-}" ]   && BOLD=$'\033[1m'
[ -z "${DIM:-}" ]    && DIM=$'\033[2m'
[ -z "${RESET:-}" ]  && RESET=$'\033[0m'
[ -z "${RED:-}" ]    && RED=$'\033[1;31m'
[ -z "${GREEN:-}" ]  && GREEN=$'\033[1;32m'
[ -z "${YELLOW:-}" ] && YELLOW=$'\033[1;33m'
[ -z "${CYAN:-}" ]   && CYAN=$'\033[1;36m'

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
    printf '%b    %s — namespace=%s release=%s%b\n' \
        "$DIM" "$(basename "$script")" "$NAMESPACE" "$RELEASE" "$RESET"
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

for entry in "${SELECTED[@]}"; do
    name="${entry%%|*}"
    script="$SCRIPT_DIR/${entry##*|}"
    run_suite "$name" "$script"
done

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
printf "  (%s total)\n\n" "$(fmttime "$TOTAL_ELAPSED")"

if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "${RED}${BOLD}TEST RUN FAILED${RESET}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL SELECTED TESTS PASSED${RESET}"
    exit 0
fi
