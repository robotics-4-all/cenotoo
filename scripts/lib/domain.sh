# =============================================================================
# scripts/lib/domain.sh — Unified domain config + render library
# -----------------------------------------------------------------------------
# Source-only library. Do NOT execute directly.
#
# Provides:
#   cenotoo_load_config    — source deploy/k8s/cenotoo.env (or .example fallback)
#   cenotoo_require_config — validate domain/email/hostname (actionable errors)
#   cenotoo_derive_hosts   — export per-host vars + shared TLS secret + namespace
#   cenotoo_render_tree    — render *.yaml.tpl via allow-listed envsubst
#   cenotoo_apply_rendered — kubectl apply a rendered tree
#   cenotoo_dns_report     — print DNS A-record table + firewall checklist
#
# Config contract (deploy/k8s/cenotoo.env.example):
#   CENOTOO_BASE_DOMAIN, CENOTOO_TLS_EMAIL, CENOTOO_NAMESPACE,
#   CENOTOO_ACME_SERVER, CENOTOO_COAP_ENABLED
# Derived at runtime:
#   CENOTOO_API_HOST, CENOTOO_DASHBOARD_HOST, CENOTOO_MQTT_HOST,
#   CENOTOO_COAP_HOST, CENOTOO_TLS_SECRET
# =============================================================================

# ---- Guard against double-sourcing ----------------------------------------
if [ "${_CENOTOO_DOMAIN_SH_LOADED:-}" = "1" ]; then return 0; fi
_CENOTOO_DOMAIN_SH_LOADED=1

set -euo pipefail

# ---- Resolve project root from this script's path (never hardcode) --------
_CENOTOO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CENOTOO_PROJECT_DIR="$(cd "$_CENOTOO_LIB_DIR/../.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$_CENOTOO_PROJECT_DIR}"

# ---- Reuse shared UI helpers (info/ok/warn/fail) without clobbering -------
if ! command -v fail &>/dev/null; then
    # shellcheck disable=SC1091
    source "$_CENOTOO_LIB_DIR/ui.sh"
fi

# ---- Config paths ----------------------------------------------------------
CENOTOO_ENV_FILE="$PROJECT_DIR/deploy/k8s/cenotoo.env"
CENOTOO_ENV_EXAMPLE="$PROJECT_DIR/deploy/k8s/cenotoo.env.example"

# ---- Render allow-list (programmatic; unknown ${VARS} pass through) --------
_CENOTOO_RENDER_VARS=(
    CENOTOO_BASE_DOMAIN
    CENOTOO_NAMESPACE
    CENOTOO_TLS_EMAIL
    CENOTOO_ACME_SERVER
    CENOTOO_API_HOST
    CENOTOO_DASHBOARD_HOST
    CENOTOO_MQTT_HOST
    CENOTOO_COAP_HOST
    CENOTOO_TLS_SECRET
)

_cenotoo_envsubst_allow() {
    local allow="" var
    for var in "${_CENOTOO_RENDER_VARS[@]}"; do
        allow="$allow\${$var}"
        allow="$allow "
    done
    printf '%s' "$allow"
}

# ---- Hostname validation ---------------------------------------------------
_cenotoo_valid_hostname() {
    local host="$1"
    # RFC 1035: labels of alphanumerics/hyphens, dots separate, <=253 chars.
    if [ "${#host}" -gt 253 ] || [ "${#host}" -lt 1 ]; then return 1; fi
    case "$host" in
        *[!A-Za-z0-9.-]* | -* | *- | *..* | *.-* | *-.*) return 1 ;;
    esac
    case "$host" in
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

# cenotoo_load_config — source the gitignored env file, else fall back to the
# committed example with exactly one warning.
cenotoo_load_config() {
    local src=""
    if [ -f "$CENOTOO_ENV_FILE" ]; then
        src="$CENOTOO_ENV_FILE"
    elif [ -f "$CENOTOO_ENV_EXAMPLE" ]; then
        warn "Config $CENOTOO_ENV_FILE not found — falling back to $CENOTOO_ENV_EXAMPLE (run scripts/set-domain.sh to persist your domain)."
        src="$CENOTOO_ENV_EXAMPLE"
    else
        fail "No domain config found: missing both $CENOTOO_ENV_FILE and $CENOTOO_ENV_EXAMPLE."
    fi
    set -a
    # shellcheck disable=SC1090
    source "$src"
    set +a
    : "${CENOTOO_NAMESPACE:=cenotoo}"
    : "${CENOTOO_ACME_SERVER:=https://acme-v02.api.letsencrypt.org/directory}"
    : "${CENOTOO_COAP_ENABLED:=false}"
    export CENOTOO_NAMESPACE CENOTOO_ACME_SERVER CENOTOO_COAP_ENABLED
}

# cenotoo_require_config — fail with actionable text on empty domain/email
# or an invalid hostname.
cenotoo_require_config() {
    if [ -z "${CENOTOO_BASE_DOMAIN:-}" ]; then
        fail "CENOTOO_BASE_DOMAIN is empty. Set it in $CENOTOO_ENV_FILE (see cenotoo.env.example) or run: scripts/set-domain.sh --domain <base-domain>."
    fi
    if ! _cenotoo_valid_hostname "$CENOTOO_BASE_DOMAIN"; then
        fail "CENOTOO_BASE_DOMAIN='$CENOTOO_BASE_DOMAIN' is not a valid hostname. Use a dotted domain with letters, digits, hyphens and dots only (e.g. example.com)."
    fi
    if [ -z "${CENOTOO_TLS_EMAIL:-}" ]; then
        fail "CENOTOO_TLS_EMAIL is empty. Set it in $CENOTOO_ENV_FILE (see cenotoo.env.example) or run: scripts/set-domain.sh --email <ops@example.com>."
    fi
    case "$CENOTOO_TLS_EMAIL" in
        *@*.*) ;;
        *) fail "CENOTOO_TLS_EMAIL='$CENOTOO_TLS_EMAIL' is not a valid email address. Use the form ops@example.com." ;;
    esac
}

# cenotoo_derive_hosts — export per-host variables, the shared TLS
# secret-name variable and the namespace.
cenotoo_derive_hosts() {
    cenotoo_require_config
    CENOTOO_API_HOST="api.${CENOTOO_BASE_DOMAIN}"
    CENOTOO_DASHBOARD_HOST="dashboard.${CENOTOO_BASE_DOMAIN}"
    CENOTOO_MQTT_HOST="mqtt.${CENOTOO_BASE_DOMAIN}"
    CENOTOO_COAP_HOST="coap.${CENOTOO_BASE_DOMAIN}"
    CENOTOO_TLS_SECRET="cenotoo-public-tls"
    : "${CENOTOO_NAMESPACE:=cenotoo}"
    export CENOTOO_API_HOST CENOTOO_DASHBOARD_HOST CENOTOO_MQTT_HOST
    export CENOTOO_COAP_HOST CENOTOO_TLS_SECRET CENOTOO_NAMESPACE
}

# cenotoo_render_tree <src-dir> [<dest-dir>]
# Render every *.yaml.tpl under <src-dir> into the gitignored rendered tree
# (default: $PROJECT_DIR/.rendered/k8s), stripping the .tpl suffix.
# Only allow-listed ${CENOTOO_*} names are expanded; unknown dollar-vars
# (e.g. ${HOME}) pass through literally.
cenotoo_render_tree() {
    local src_dir="${1:?Usage: cenotoo_render_tree <src-dir> [<dest-dir>]}"
    local dest_dir="${2:-$PROJECT_DIR/.rendered/k8s}"
    if [ ! -d "$src_dir" ]; then
        fail "Template dir not found: $src_dir."
    fi
    if ! command -v envsubst &>/dev/null; then
        fail "'envsubst' is required but not installed (package: gettext)."
    fi
    if [ -z "${CENOTOO_API_HOST:-}" ]; then
        cenotoo_derive_hosts
    fi
    local allow tpl rel dest count=0
    allow="$(_cenotoo_envsubst_allow)"
    while IFS= read -r tpl; do
        rel="${tpl#"$src_dir"/}"
        dest="$dest_dir/${rel%.tpl}"
        mkdir -p "$(dirname "$dest")"
        envsubst "$allow" < "$tpl" > "$dest"
        count=$((count + 1))
    done < <(find "$src_dir" -type f -name '*.yaml.tpl' | sort)
    info "Rendered $count template(s) from $src_dir to $dest_dir"
}

# cenotoo_apply_rendered [<rendered-dir>]
# Run kubectl apply on a rendered tree.
cenotoo_apply_rendered() {
    local rendered_dir="${1:-$PROJECT_DIR/.rendered/k8s}"
    if [ ! -d "$rendered_dir" ]; then
        fail "Rendered tree not found: $rendered_dir. Render templates first with cenotoo_render_tree."
    fi
    if ! command -v kubectl &>/dev/null; then
        fail "'kubectl' is required but not installed."
    fi
    kubectl apply -f "$rendered_dir"
}

# cenotoo_dns_report — print the DNS A-record table plus the firewall
# checklist. Never prints secret material.
cenotoo_dns_report() {
    if [ -z "${CENOTOO_API_HOST:-}" ]; then
        cenotoo_derive_hosts
    fi
    echo ""
    echo "DNS A records (point each at the k3s node's public IP):"
    printf '  %-28s -> <node-public-ip>\n' "$CENOTOO_API_HOST" "$CENOTOO_DASHBOARD_HOST" "$CENOTOO_MQTT_HOST"
    if [ "${CENOTOO_COAP_ENABLED:-false}" = "true" ]; then
        printf '  %-28s -> <node-public-ip> (CoAP enabled)\n' "$CENOTOO_COAP_HOST"
    fi
    echo ""
    echo "Firewall checklist:"
    echo "  ALLOW 80/tcp   (HTTP + ACME HTTP-01 challenge path)"
    echo "  ALLOW 443/tcp  (HTTPS: api + dashboard)"
    echo "  ALLOW 8883/tcp (MQTT over TLS)"
    echo "  CLOSE 30080, 30081, 30683 (legacy NodePorts)"
    echo ""
}
