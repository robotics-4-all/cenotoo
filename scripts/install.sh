#!/usr/bin/env bash
# =============================================================================
# scripts/install.sh — Cenotoo guided installer
# -----------------------------------------------------------------------------
# Top-level interactive orchestrator that wraps the existing 01-..-24- scripts.
# Designed for clean Ubuntu 22.04 / 24.04 hosts (e.g. a fresh GCP VM).
#
# Flow:
#   1. Preflight    — OS / sudo / CPU / RAM / disk / dependencies
#   2. Configure    — interactive questionnaire (or load from .install.conf)
#   3. Plan         — print exactly what will run, ask to confirm
#   4. Install      — run scripts in order, with idempotent behavior
#   5. Summary      — credentials, URLs, next steps
#
# Idempotent: safe to re-run. Each underlying script detects existing state.
#
# Usage:
#   sudo ./scripts/install.sh                  # full guided flow
#   sudo ./scripts/install.sh --plan-only      # show plan and exit
#   sudo ./scripts/install.sh --resume         # use saved .install.conf, no prompts
#   sudo ./scripts/install.sh --uninstall      # remove cenotoo namespace + manifests
#   sudo ./scripts/install.sh --no-monitoring  # force-skip monitoring
#   sudo ./scripts/install.sh --help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

# ---- Paths ----------------------------------------------------------------
CONF_FILE="$PROJECT_DIR/.install.conf"
SECRETS_OUT_DIR="$PROJECT_DIR/.secrets"
SECRETS_OUT_FILE="$SECRETS_OUT_DIR/credentials.txt"
LOG_FILE="$PROJECT_DIR/.install.log"

# ---- Defaults / minimums --------------------------------------------------
MIN_CPU=2
MIN_RAM_MB=3500            # ~4 GB (allow for kernel overhead)
MIN_DISK_GB=20
RECOMMENDED_RAM_MB=15000   # ~16 GB

# ---- Argument parsing -----------------------------------------------------
MODE="install"
RESUME=false
PLAN_ONLY=false
FORCE_NO_MONITORING=false

usage() {
    cat <<EOF
Cenotoo guided installer

Usage:  sudo $0 [options]

Options:
  --plan-only        Print the install plan and exit (no changes made).
  --resume           Use the saved .install.conf and skip interactive prompts.
  --uninstall        Remove the cenotoo namespace and its manifests.
  --no-monitoring    Skip the Prometheus + Grafana stack.
  -h, --help         Show this help and exit.

Files written:
  .install.conf      Saved configuration (re-used by --resume).
  .secrets/credentials.txt   Generated passwords/secrets (chmod 600).
  .install.log       Combined install log.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --plan-only)     PLAN_ONLY=true ;;
        --resume)        RESUME=true ;;
        --uninstall)     MODE="uninstall" ;;
        --no-monitoring) FORCE_NO_MONITORING=true ;;
        -h|--help)       usage; exit 0 ;;
        *) fail "Unknown option: $arg (try --help)" ;;
    esac
done

# ---- Logging tee ----------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

banner "Cenotoo Installer"

# =============================================================================
# Uninstall path
# =============================================================================
if [ "$MODE" = "uninstall" ]; then
    require_root
    require_cmd kubectl
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

    warn "This will delete the 'cenotoo' namespace and all data."
    prompt_yesno CONFIRM "Are you sure?" "n"
    [ "$CONFIRM" = "true" ] || { info "Aborted."; exit 0; }

    kubectl delete namespace cenotoo --wait=false 2>/dev/null || true
    info "Namespace 'cenotoo' deletion requested."
    info "k3s itself was NOT removed. To wipe k3s entirely:"
    dimtext "  /usr/local/bin/k3s-uninstall.sh"
    exit 0
fi

# =============================================================================
# 1. PREFLIGHT
# =============================================================================
step 1 5 "Preflight checks"

require_root

# OS check (Ubuntu 22.04 / 24.04 supported, others warn)
if [ ! -f /etc/os-release ]; then
    fail "Cannot detect OS — /etc/os-release missing"
fi
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
case "$OS_ID:$OS_VERSION" in
    ubuntu:22.04|ubuntu:24.04) ok "OS: Ubuntu $OS_VERSION (supported)" ;;
    ubuntu:*)                  warn "OS: Ubuntu $OS_VERSION (untested but should work)" ;;
    debian:*)                  warn "OS: Debian $OS_VERSION (untested but should work)" ;;
    *)                         warn "OS: $OS_ID $OS_VERSION (not officially supported)" ;;
esac

# CPU
CPU_COUNT="$(nproc)"
if [ "$CPU_COUNT" -lt "$MIN_CPU" ]; then
    fail "CPU: $CPU_COUNT cores (minimum $MIN_CPU required)"
fi
ok "CPU: $CPU_COUNT cores"

# RAM
RAM_MB="$(awk '/^MemTotal:/ { printf "%d\n", $2/1024 }' /proc/meminfo)"
if [ "$RAM_MB" -lt "$MIN_RAM_MB" ]; then
    fail "RAM: ${RAM_MB} MB (minimum $((MIN_RAM_MB / 1024)) GB required)"
fi
if [ "$RAM_MB" -lt "$RECOMMENDED_RAM_MB" ]; then
    warn "RAM: ${RAM_MB} MB (less than $((RECOMMENDED_RAM_MB / 1024)) GB recommended — consider --no-monitoring)"
else
    ok "RAM: ${RAM_MB} MB"
fi

# Disk (root partition free space)
DISK_FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "$DISK_FREE_GB" -lt "$MIN_DISK_GB" ]; then
    fail "Disk: ${DISK_FREE_GB} GB free on / (minimum $MIN_DISK_GB GB required)"
fi
ok "Disk: ${DISK_FREE_GB} GB free"

# Required commands (install missing ones from apt where possible)
APT_INSTALL=()
for cmd in curl openssl git; do
    if ! command -v "$cmd" &>/dev/null; then
        APT_INSTALL+=("$cmd")
    fi
done
if [ "${#APT_INSTALL[@]}" -gt 0 ]; then
    info "Installing missing packages: ${APT_INSTALL[*]}"
    apt-get update -qq
    apt-get install -y "${APT_INSTALL[@]}"
fi
for cmd in curl openssl git; do require_cmd "$cmd"; done
ok "Tooling: curl, openssl, git"

# Docker — required for building images
if ! command -v docker &>/dev/null; then
    warn "Docker not installed — installing via convenience script"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi
ok "Docker: $(docker --version 2>/dev/null | head -1)"

# Detect external IP for later
EXTERNAL_IP="$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo '')"
if [ -n "$EXTERNAL_IP" ]; then
    ok "External IP: $EXTERNAL_IP"
else
    warn "Could not detect external IP (no internet?). Continuing."
fi

# =============================================================================
# 2. CONFIGURE
# =============================================================================
step 2 5 "Configuration"

if [ "$RESUME" = "true" ]; then
    if [ ! -f "$CONF_FILE" ]; then
        fail "--resume specified but $CONF_FILE not found. Run without --resume first."
    fi
    info "Loading saved configuration from $CONF_FILE"
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    ok "Configuration loaded"
else
    # ---- Exposure model ---------------------------------------------------
    prompt_choice EXPOSE_CHOICE "How should services be exposed publicly?" \
        "NodePort + GCP firewall (simplest — no domain needed)" \
        "Ingress + TLS via Let's Encrypt (requires domain pointed at this VM)"

    if [ "$EXPOSE_CHOICE" = "1" ]; then
        EXPOSE_MODE="nodeport"
        DOMAIN=""
        TLS_EMAIL=""
    else
        EXPOSE_MODE="ingress-tls"
        if [ -z "$EXTERNAL_IP" ]; then
            warn "No external IP detected — TLS via Let's Encrypt requires a public IP."
            prompt_yesno CONT "Continue anyway?" "n"
            [ "$CONT" = "true" ] || exit 1
        fi
        prompt DOMAIN "Domain name (e.g. cenotoo.example.com):" ""
        while [ -z "$DOMAIN" ]; do
            warn "Domain is required for ingress-tls mode."
            prompt DOMAIN "Domain name:" ""
        done
        prompt TLS_EMAIL "Email for Let's Encrypt notifications:" ""
        while [ -z "$TLS_EMAIL" ]; do
            warn "Email is required by Let's Encrypt."
            prompt TLS_EMAIL "Email for Let's Encrypt:" ""
        done
    fi

    # ---- Secrets (hybrid: auto-generate, allow override) ------------------
    echo ""
    info "Secret generation — press Enter to auto-generate, or paste a value."
    echo ""
    prompt_secret JWT_SECRET           "JWT signing secret"          "auto"
    prompt_secret API_KEY_SECRET       "API key signing secret"      "auto"
    prompt_secret CASSANDRA_PASSWORD   "Cassandra superuser password" "auto"
    prompt_secret POSTGRES_PASSWORD    "PostgreSQL password"          "auto"
    prompt_secret ADMIN_PASSWORD       "Cenotoo admin user password"  "auto"

    # ---- Optional components ---------------------------------------------
    echo ""
    if [ "$FORCE_NO_MONITORING" = "true" ]; then
        INSTALL_MONITORING=false
        info "Monitoring: skipped (--no-monitoring)"
    else
        prompt_yesno INSTALL_MONITORING "Install Prometheus + Grafana monitoring stack? (~2 GB RAM)" "y"
    fi
    prompt_yesno INSTALL_MQTT      "Install MQTT bridge (Mosquitto)?" "y"
    prompt_yesno INSTALL_COAP      "Install CoAP bridge?"             "y"
    prompt_yesno INSTALL_FLINK_JOBS "Install Flink stream-processing jobs?" "y"

    # Dashboard requires external repo
    DEFAULT_DASHBOARD="y"
    if [ ! -d "$PROJECT_DIR/../cenotoo-dashboard" ]; then
        DEFAULT_DASHBOARD="n"
    fi
    prompt_yesno INSTALL_DASHBOARD "Install web dashboard? (requires ../cenotoo-dashboard checkout)" "$DEFAULT_DASHBOARD"

    # ---- Persist config ---------------------------------------------------
    umask 077
    cat > "$CONF_FILE" <<EOF
# Cenotoo install configuration — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Re-use with: sudo ./scripts/install.sh --resume
EXPOSE_MODE="$EXPOSE_MODE"
DOMAIN="$DOMAIN"
TLS_EMAIL="$TLS_EMAIL"
JWT_SECRET="$JWT_SECRET"
API_KEY_SECRET="$API_KEY_SECRET"
CASSANDRA_PASSWORD="$CASSANDRA_PASSWORD"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
INSTALL_MONITORING=$INSTALL_MONITORING
INSTALL_MQTT=$INSTALL_MQTT
INSTALL_COAP=$INSTALL_COAP
INSTALL_FLINK_JOBS=$INSTALL_FLINK_JOBS
INSTALL_DASHBOARD=$INSTALL_DASHBOARD
EOF
    chmod 600 "$CONF_FILE"
    ok "Configuration saved to $CONF_FILE (chmod 600)"
fi

# =============================================================================
# 3. PLAN
# =============================================================================
step 3 5 "Plan"

PLAN=()
PLAN+=("01-install-k3s.sh                  → k3s + Helm + kubectl")
PLAN+=("02-install-cert-manager.sh         → cert-manager (TLS certificates)")
PLAN+=("03-install-strimzi-operator.sh     → Kafka operator")
PLAN+=("04-install-k8ssandra-operator.sh   → Cassandra operator (if present)")
PLAN+=("05-install-flink-operator.sh       → Flink operator")
[ "$INSTALL_MONITORING" = "true" ] && \
PLAN+=("06-install-monitoring.sh           → Prometheus + Grafana")
PLAN+=("configure-secrets.sh               → write K8s Secret manifests")
PLAN+=("07-deploy-cenotoo.sh               → namespace + Kafka + Cassandra + consumers + API")
PLAN+=("24-deploy-postgres.sh              → PostgreSQL metadata store")
PLAN+=("08-deploy-api.sh                   → REST API")
[ "$INSTALL_MQTT" = "true" ] && \
PLAN+=("12-deploy-mqtt-bridge.sh           → Mosquitto + MQTT bridge")
[ "$INSTALL_COAP" = "true" ] && \
PLAN+=("22-deploy-coap-bridge.sh           → CoAP bridge")
[ "$INSTALL_DASHBOARD" = "true" ] && \
PLAN+=("10-deploy-dashboard.sh             → Web dashboard")
[ "$INSTALL_FLINK_JOBS" = "true" ] && \
PLAN+=("11-deploy-flink-jobs.sh            → Flink SQL gateway + jobs")
[ "$EXPOSE_MODE" = "ingress-tls" ] && \
PLAN+=("09-expose-api.sh                   → Ingress + TLS for $DOMAIN")

echo -e "  ${BOLD}Steps to execute (in order):${RESET}"
for entry in "${PLAN[@]}"; do
    echo -e "    ${DIM}•${RESET} $entry"
done
echo ""
echo -e "  ${BOLD}Configuration:${RESET}"
echo -e "    Exposure mode : ${BOLD}$EXPOSE_MODE${RESET}"
[ -n "$DOMAIN" ]      && echo -e "    Domain        : ${BOLD}$DOMAIN${RESET}"
[ -n "$TLS_EMAIL" ]   && echo -e "    LE email      : ${BOLD}$TLS_EMAIL${RESET}"
echo -e "    Monitoring    : $INSTALL_MONITORING"
echo -e "    MQTT bridge   : $INSTALL_MQTT"
echo -e "    CoAP bridge   : $INSTALL_COAP"
echo -e "    Flink jobs    : $INSTALL_FLINK_JOBS"
echo -e "    Dashboard     : $INSTALL_DASHBOARD"
echo ""

if [ "$PLAN_ONLY" = "true" ]; then
    info "--plan-only specified — exiting without making changes."
    exit 0
fi

prompt_yesno PROCEED "Proceed with installation?" "y"
[ "$PROCEED" = "true" ] || { info "Aborted."; exit 0; }

# =============================================================================
# 4. INSTALL
# =============================================================================
step 4 5 "Installation"

run_step() {
    local script="$1"
    local label="${2:-$script}"
    local path="$SCRIPT_DIR/$script"
    if [ ! -x "$path" ]; then
        if [ -f "$path" ]; then
            chmod +x "$path"
        else
            warn "Script not found: $script — skipping"
            return 0
        fi
    fi
    hr
    info "→ $label"
    hr
    if ! "$path"; then
        fail "Step failed: $label  (see $LOG_FILE)"
    fi
}

# ---- Infra operators ------------------------------------------------------
run_step "01-install-k3s.sh"               "Install k3s"
run_step "02-install-cert-manager.sh"      "Install cert-manager"
run_step "03-install-strimzi-operator.sh"  "Install Strimzi (Kafka operator)"

# K8ssandra is optional/legacy in some setups — skip cleanly if missing
if [ -x "$SCRIPT_DIR/04-install-k8ssandra-operator.sh" ]; then
    run_step "04-install-k8ssandra-operator.sh" "Install K8ssandra (Cassandra operator)"
fi

run_step "05-install-flink-operator.sh"    "Install Flink operator"

if [ "$INSTALL_MONITORING" = "true" ]; then
    run_step "06-install-monitoring.sh"    "Install Prometheus + Grafana"
fi

# ---- Secrets --------------------------------------------------------------
hr
info "→ Configure secrets (non-interactive — values from .install.conf)"
hr
export CENOTOO_JWT_SECRET="$JWT_SECRET"
export CENOTOO_API_KEY_SECRET="$API_KEY_SECRET"
export CENOTOO_CASSANDRA_PASSWORD="$CASSANDRA_PASSWORD"
export CENOTOO_POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
# Pipe empty input so configure-secrets.sh accepts the env-provided defaults
if ! "$SCRIPT_DIR/configure-secrets.sh" </dev/null; then
    fail "configure-secrets.sh failed (see $LOG_FILE)"
fi

# 07-deploy-cenotoo.sh demands EVERY *.yaml.example has a matching *.yaml,
# including mqtt-credentials.yaml — but that file is owned by 12-deploy-mqtt-bridge.sh.
# Pre-create a placeholder so the deploy preflight passes; 12 will overwrite it
# with real credentials when the MQTT bridge is installed.
SECRETS_DIR="$PROJECT_DIR/deploy/k8s/01-secrets"
if [ -f "$SECRETS_DIR/mqtt-credentials.yaml.example" ] && \
   [ ! -f "$SECRETS_DIR/mqtt-credentials.yaml" ]; then
    info "Pre-creating placeholder mqtt-credentials.yaml (will be overwritten by MQTT deploy)"
    PLACEHOLDER_USER=$(printf '%s' "placeholder" | base64 -w0 2>/dev/null || printf '%s' "placeholder" | base64)
    PLACEHOLDER_PASS=$(printf '%s' "placeholder-replace-me" | base64 -w0 2>/dev/null || printf '%s' "placeholder-replace-me" | base64)
    cat > "$SECRETS_DIR/mqtt-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cenotoo-mqtt-credentials
  labels:
    app.kubernetes.io/component: mqtt-broker
    app.kubernetes.io/part-of: cenotoo
type: Opaque
data:
  username: $PLACEHOLDER_USER
  password: $PLACEHOLDER_PASS
EOF
    chmod 600 "$SECRETS_DIR/mqtt-credentials.yaml"
fi

# ---- Build images BEFORE deploying so pods don't crash-loop on missing image
hr
info "→ Build local Docker images"
hr
if ! "$SCRIPT_DIR/build-images.sh"; then
    warn "build-images.sh exited non-zero — some images may be missing"
fi

# Export admin credentials BEFORE 07-deploy-cenotoo.sh: it calls
# init-cassandra-schema.sh which now reads these vars instead of prompting
# (we run under tee, so stdin is not a TTY and an interactive read would hang).
export CENOTOO_ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
export CENOTOO_ADMIN_PASSWORD="$ADMIN_PASSWORD"

# ---- Deploy core ----------------------------------------------------------
run_step "07-deploy-cenotoo.sh"   "Deploy Cenotoo core (Kafka, Cassandra, consumers)"
run_step "24-deploy-postgres.sh"  "Deploy PostgreSQL metadata store"
run_step "08-deploy-api.sh"       "Deploy REST API"

# ---- Optional bridges -----------------------------------------------------
if [ "$INSTALL_MQTT" = "true" ]; then
    run_step "12-deploy-mqtt-bridge.sh" "Deploy MQTT bridge"
fi

if [ "$INSTALL_COAP" = "true" ]; then
    run_step "22-deploy-coap-bridge.sh" "Deploy CoAP bridge"
fi

if [ "$INSTALL_DASHBOARD" = "true" ]; then
    if [ -d "$PROJECT_DIR/../cenotoo-dashboard" ]; then
        run_step "10-deploy-dashboard.sh" "Deploy web dashboard"
    else
        warn "Dashboard requested but ../cenotoo-dashboard not found — skipping"
    fi
fi

if [ "$INSTALL_FLINK_JOBS" = "true" ]; then
    run_step "11-deploy-flink-jobs.sh" "Deploy Flink jobs"
fi

# ---- Public exposure (TLS) ------------------------------------------------
if [ "$EXPOSE_MODE" = "ingress-tls" ]; then
    hr
    info "→ Expose API with TLS for $DOMAIN"
    hr
    export CENOTOO_DOMAIN="$DOMAIN"
    export CENOTOO_TLS_EMAIL="$TLS_EMAIL"
    if ! "$SCRIPT_DIR/09-expose-api.sh"; then
        warn "09-expose-api.sh exited non-zero — you may need to run it manually."
    fi
fi

# =============================================================================
# 5. SUMMARY
# =============================================================================
step 5 5 "Summary"

# Persist credentials with restrictive permissions
mkdir -p "$SECRETS_OUT_DIR"
chmod 700 "$SECRETS_OUT_DIR"
umask 077
cat > "$SECRETS_OUT_FILE" <<EOF
# Cenotoo credentials — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# KEEP THIS FILE PRIVATE. After saving to a password manager, delete it:
#   shred -u $SECRETS_OUT_FILE

JWT_SECRET=$JWT_SECRET
API_KEY_SECRET=$API_KEY_SECRET
CASSANDRA_PASSWORD=$CASSANDRA_PASSWORD
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
chmod 600 "$SECRETS_OUT_FILE"

# URLs
NODE_IP="${EXTERNAL_IP:-}"
[ -z "$NODE_IP" ] && NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo '<node-ip>')"

if [ "$EXPOSE_MODE" = "ingress-tls" ]; then
    API_URL="https://$DOMAIN"
    DOCS_URL="https://$DOMAIN/docs"
else
    API_URL="http://$NODE_IP:30080"
    DOCS_URL="http://$NODE_IP:30080/docs"
fi

echo ""
box \
    "${GREEN}${BOLD}Cenotoo installed successfully${RESET}" \
    "" \
    "API:       $API_URL" \
    "Docs:      $DOCS_URL" \
    "Admin:     admin / (see .secrets/credentials.txt)"
echo ""

echo -e "  ${BOLD}Next steps${RESET}"
echo ""
echo -e "  1. ${BOLD}Verify the API:${RESET}"
echo -e "     curl $API_URL/health"
echo ""
echo -e "  2. ${BOLD}View your credentials:${RESET}"
echo -e "     sudo cat $SECRETS_OUT_FILE"
echo ""
echo -e "  3. ${BOLD}Watch the cluster:${RESET}"
echo -e "     kubectl get pods -n cenotoo -w"
echo ""
echo -e "  4. ${BOLD}Login & get a token:${RESET}"
echo -e "     curl -X POST $API_URL/api/v1/token \\"
echo -e "       -d 'username=admin&password=<see-credentials-file>'"
echo ""

if [ "$EXPOSE_MODE" = "nodeport" ]; then
    echo -e "  ${YELLOW}Reminder:${RESET} on GCP, open the relevant ports in the VPC firewall:"
    echo -e "    ${DIM}gcloud compute firewall-rules create cenotoo-http \\${RESET}"
    echo -e "    ${DIM}  --rules=tcp:30080,tcp:30081 --target-tags=cenotoo \\${RESET}"
    echo -e "    ${DIM}  --source-ranges=0.0.0.0/0${RESET}"
    [ "$INSTALL_MQTT" = "true" ] && echo -e "    ${DIM}# MQTT: --rules=tcp:1883${RESET}"
    [ "$INSTALL_COAP" = "true" ] && echo -e "    ${DIM}# CoAP: --rules=udp:30683${RESET}"
    echo ""
fi

echo -e "  ${DIM}Full log: $LOG_FILE${RESET}"
echo -e "  ${DIM}Re-run with the same answers: sudo $0 --resume${RESET}"
echo ""
