# =============================================================================
# scripts/lib/ui.sh — Shared UI helpers for Cenotoo install scripts
# -----------------------------------------------------------------------------
# Source-only library. Do NOT execute directly.
#
# Provides:
#   - Color constants
#   - Logging helpers: info / ok / warn / fail / step / dimtext / hr
#   - Banner / box renderers
#   - Interactive prompts: prompt / prompt_secret / prompt_choice / prompt_yesno
#   - Random secret generator
#
# All helpers respect NO_COLOR=1 to disable ANSI sequences (for piping/CI).
# =============================================================================

# ---- Guard against double-sourcing ----------------------------------------
if [ "${_CENOTOO_UI_SH_LOADED:-}" = "1" ]; then return 0; fi
_CENOTOO_UI_SH_LOADED=1

# ---- Colors ---------------------------------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    BOLD='\033[1m'; DIM='\033[2m'
    RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    BLUE='\033[1;34m'; CYAN='\033[1;36m'; MAGENTA='\033[1;35m'
    RESET='\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''
    BLUE=''; CYAN=''; MAGENTA=''; RESET=''
fi

# ---- Logging --------------------------------------------------------------
info()    { echo -e "  ${BLUE}▸${RESET} $*"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }
dimtext() { echo -e "  ${DIM}$*${RESET}"; }
hr()      { echo -e "  ${DIM}────────────────────────────────────────────────${RESET}"; }

# step <n> <total> <title>
step() {
    local n="$1" total="$2" title="$3"
    echo ""
    echo -e "${BOLD}${CYAN}[$n/$total]${RESET} ${BOLD}$title${RESET}"
    echo ""
}

# banner <title-line>
banner() {
    local title="$1"
    local pad len width=58
    len=${#title}
    pad=$(( (width - len) / 2 ))
    local left=""; local right=""
    printf -v left  "%*s" "$pad" ""
    printf -v right "%*s" "$(( width - len - pad ))" ""
    echo ""
    echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}  ║${left}${title}${right}║${RESET}"
    echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# box <line> [<line>...]
box() {
    local lines=("$@")
    local inner=58
    echo -e "  ${GREEN}┌──────────────────────────────────────────────────────────┐${RESET}"
    for line in "${lines[@]}"; do
        local plain
        plain="$(printf '%b' "$line" | sed -E 's/\x1b\[[0-9;]*m//g')"
        local len=${#plain}
        local pad=$(( inner - len - 2 ))
        [ "$pad" -lt 0 ] && pad=0
        printf "  ${GREEN}│${RESET} %b%*s ${GREEN}│${RESET}\n" "$line" "$pad" ""
    done
    echo -e "  ${GREEN}└──────────────────────────────────────────────────────────┘${RESET}"
}

# ---- Prompts --------------------------------------------------------------

# prompt <var-name> <prompt-text> [default]
prompt() {
    local var_name="$1" text="$2" default="${3:-}"
    local value
    if [ -n "$default" ]; then
        echo -en "  ${BLUE}▸${RESET} ${text} ${DIM}[${default}]${RESET} "
    else
        echo -en "  ${BLUE}▸${RESET} ${text} "
    fi
    read -r value
    value="${value:-$default}"
    eval "$var_name=\"\$value\""
}

# prompt_secret <var-name> <prompt-text> [default-display]
# Reads input silently. If user submits empty AND default-display is "auto",
# generates a random hex secret. If default-display is empty and user submits
# nothing, returns empty.
prompt_secret() {
    local var_name="$1" text="$2" default="${3:-}"
    local value
    if [ -n "$default" ]; then
        echo -en "  ${BLUE}▸${RESET} ${text} ${DIM}[${default}]${RESET} "
    else
        echo -en "  ${BLUE}▸${RESET} ${text} "
    fi
    read -rs value
    echo ""
    if [ -z "$value" ] && [ "$default" = "auto" ]; then
        value="$(rand_secret)"
    fi
    eval "$var_name=\"\$value\""
}

# prompt_yesno <var-name> <prompt-text> <default y|n>
prompt_yesno() {
    local var_name="$1" text="$2" default="${3:-y}"
    local hint value
    if [ "$default" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        echo -en "  ${BLUE}▸${RESET} ${text} ${DIM}[${hint}]${RESET} "
        read -r value
        value="${value:-$default}"
        case "$value" in
            y|Y|yes|YES) eval "$var_name=true";  return ;;
            n|N|no|NO)   eval "$var_name=false"; return ;;
            *) warn "Please answer y or n" ;;
        esac
    done
}

# prompt_choice <var-name> <prompt-text> <option-1> <option-2> ...
# Returns the 1-based index of the chosen option in <var-name>.
prompt_choice() {
    local var_name="$1" text="$2"
    shift 2
    local options=("$@")
    echo -e "  ${BLUE}▸${RESET} ${text}"
    local i
    for i in "${!options[@]}"; do
        echo -e "    ${BOLD}$((i+1)))${RESET} ${options[$i]}"
    done
    local choice
    while true; do
        echo -en "    ${DIM}Choice:${RESET} "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            eval "$var_name=\"\$choice\""
            return
        fi
        warn "Enter a number between 1 and ${#options[@]}"
    done
}

# ---- Misc helpers ---------------------------------------------------------

rand_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 32
    else
        # Fallback: /dev/urandom
        head -c 32 /dev/urandom | xxd -p -c 64
    fi
}

# require_cmd <cmd> [<install-hint>]
require_cmd() {
    local cmd="$1" hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        if [ -n "$hint" ]; then
            fail "'$cmd' is required but not installed. $hint"
        else
            fail "'$cmd' is required but not installed."
        fi
    fi
}

# require_root — abort if not running as root
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        fail "This script must be run as root (use sudo)."
    fi
}
