#!/usr/bin/env bash
# =============================================================================
# scripts/set-domain.sh — Persist the unified domain config for TLS ingress
# -----------------------------------------------------------------------------
# Config contract (deploy/k8s/cenotoo.env, gitignored):
#   CENOTOO_BASE_DOMAIN, CENOTOO_TLS_EMAIL, CENOTOO_NAMESPACE,
#   CENOTOO_ACME_SERVER, CENOTOO_COAP_ENABLED
#
# Usage:
#   scripts/set-domain.sh [--domain <base-domain>] [--email <contact>]
#                         [--show] [--reset] [--apply] [--yes]
#   No args          -> interactive prompts (domain + contact, then save).
#   --show           -> print derived hosts + DNS/firewall checklist, write nothing.
#   --reset          -> rename cenotoo.env to cenotoo.env.bak.<timestamp>;
#                       cluster objects are left untouched.
#   --apply          -> after persisting, run scripts/09-expose-api.sh
#                       --non-interactive (Task 9 interface).
#   --yes            -> skip confirmation prompts (scripting).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/domain.sh"

EXPOSE_SCRIPT="$PROJECT_DIR/scripts/09-expose-api.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Persist the unified domain config to deploy/k8s/cenotoo.env (mode 0644).

Options:
  --domain <base-domain>   Base domain to persist (e.g. example.com).
  --email <contact>        Contact address for ACME registration.
  --show                   Print derived hosts + DNS/firewall checklist; write nothing.
  --reset                  Move cenotoo.env to cenotoo.env.bak.<timestamp>.
                           Cluster objects are left untouched.
  --apply                  After persisting, run 09-expose-api.sh --non-interactive.
  --yes, -y                Skip confirmation prompts (scripting).
  --help, -h               Show this help.

With no options, prompts interactively for domain and contact address.
EOF
}

# NOTE: flag names avoid ui.sh color constants (e.g. RESET) — clobbering one
# leaks its value into every info/ok/warn line.
DO_SHOW=false
DO_RESET=false
DO_APPLY=false
ASSUME_YES=false
DOMAIN_ARG=""
EMAIL_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --domain)
            [ "$#" -lt 2 ] && fail "Option --domain requires a value."
            DOMAIN_ARG="$2"
            shift 2
            ;;
        --domain=*)
            DOMAIN_ARG="${1#--domain=}"
            shift
            ;;
        --email)
            [ "$#" -lt 2 ] && fail "Option --email requires a value."
            EMAIL_ARG="$2"
            shift 2
            ;;
        --email=*)
            EMAIL_ARG="${1#--email=}"
            shift
            ;;
        --show)
            DO_SHOW=true
            shift
            ;;
        --reset)
            DO_RESET=true
            shift
            ;;
        --apply)
            DO_APPLY=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1. See --help."
            ;;
    esac
done

# ---- --show: print derived hosts, write nothing ------------------------------
if [ "$DO_SHOW" = "true" ]; then
    cenotoo_load_config
    cenotoo_derive_hosts
    info "Base domain: $CENOTOO_BASE_DOMAIN"
    info "Contact address: $CENOTOO_TLS_EMAIL"
    info "Namespace: $CENOTOO_NAMESPACE"
    echo ""
    echo "Derived hosts:"
    echo "  API:       $CENOTOO_API_HOST"
    echo "  Dashboard: $CENOTOO_DASHBOARD_HOST"
    echo "  MQTT:      $CENOTOO_MQTT_HOST"
    if [ "${CENOTOO_COAP_ENABLED:-false}" = "true" ]; then
        echo "  CoAP:      $CENOTOO_COAP_HOST"
    fi
    echo "  TLS secret: $CENOTOO_TLS_SECRET"
    cenotoo_dns_report
    exit 0
fi

# ---- --reset: timestamped backup, cluster objects untouched ------------------
if [ "$DO_RESET" = "true" ]; then
    if [ -f "$CENOTOO_ENV_FILE" ]; then
        stamp="$(date +%Y%m%d%H%M%S)"
        backup="${CENOTOO_ENV_FILE}.bak.${stamp}"
        mv "$CENOTOO_ENV_FILE" "$backup"
        ok "Moved $CENOTOO_ENV_FILE to $backup."
    else
        warn "No config file at $CENOTOO_ENV_FILE — nothing to reset."
    fi
    info "Cluster objects are untouched (reset only removes the local config file)."
    exit 0
fi

# ---- Resolve domain + contact (flags win, else existing, else interactive) ---
cenotoo_load_config

NEW_DOMAIN="${DOMAIN_ARG:-${CENOTOO_BASE_DOMAIN:-}}"
NEW_EMAIL="${EMAIL_ARG:-${CENOTOO_TLS_EMAIL:-}}"

if [ -z "$DOMAIN_ARG" ] && [ -z "$EMAIL_ARG" ]; then
    # Interactive mode: no args given.
    prompt NEW_DOMAIN "Base domain" "$NEW_DOMAIN"
    prompt NEW_EMAIL "Contact address for ACME registration" "$NEW_EMAIL"
fi

CENOTOO_BASE_DOMAIN="$NEW_DOMAIN"
CENOTOO_TLS_EMAIL="$NEW_EMAIL"
export CENOTOO_BASE_DOMAIN CENOTOO_TLS_EMAIL

# Validate BEFORE writing: invalid domain/email exits non-zero, writes nothing.
cenotoo_derive_hosts

if [ "$ASSUME_YES" != "true" ]; then
    echo ""
    echo "Config to persist:"
    echo "  CENOTOO_BASE_DOMAIN=$CENOTOO_BASE_DOMAIN"
    echo "  CENOTOO_TLS_EMAIL=$CENOTOO_TLS_EMAIL"
    echo "  CENOTOO_NAMESPACE=${CENOTOO_NAMESPACE:-cenotoo}"
    echo "  CENOTOO_ACME_SERVER=${CENOTOO_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
    echo "  CENOTOO_COAP_ENABLED=${CENOTOO_COAP_ENABLED:-false}"
    echo ""
    SAVE_CONFIRM=true
    prompt_yesno SAVE_CONFIRM "Write $CENOTOO_ENV_FILE?" "y"
    if [ "$SAVE_CONFIRM" != "true" ]; then
        info "Aborted — no file written."
        exit 0
    fi
fi

{
    printf 'CENOTOO_BASE_DOMAIN=%s\n' "$CENOTOO_BASE_DOMAIN"
    printf 'CENOTOO_TLS_EMAIL=%s\n' "$CENOTOO_TLS_EMAIL"
    printf 'CENOTOO_NAMESPACE=%s\n' "${CENOTOO_NAMESPACE:-cenotoo}"
    printf 'CENOTOO_ACME_SERVER=%s\n' "${CENOTOO_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
    printf 'CENOTOO_COAP_ENABLED=%s\n' "${CENOTOO_COAP_ENABLED:-false}"
} > "$CENOTOO_ENV_FILE"
chmod 0644 "$CENOTOO_ENV_FILE"
ok "Wrote $CENOTOO_ENV_FILE (mode 0644)."

cenotoo_dns_report

# ---- --apply: chain into the expose script (Task 9 interface) ----------------
if [ "$DO_APPLY" = "true" ]; then
    if [ ! -x "$EXPOSE_SCRIPT" ] && [ ! -f "$EXPOSE_SCRIPT" ]; then
        warn "Apply step skipped: $EXPOSE_SCRIPT not found (lands in Task 9). Config above is persisted; re-run with --apply once the expose script exists."
        exit 0
    fi
    info "Applying public exposure via $EXPOSE_SCRIPT --non-interactive ..."
    bash "$EXPOSE_SCRIPT" --non-interactive
fi
