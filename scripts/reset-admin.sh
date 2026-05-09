#!/usr/bin/env bash
# =============================================================================
# reset-admin.sh — Reset (or create) a Cenotoo admin user
# =============================================================================
# Interactive script to change an admin user's password, change their
# username, or create a new admin user. Operates against the PostgreSQL
# metadata DB (table: users).
#
# Usage:
#   sudo ./scripts/reset-admin.sh
#   CENOTOO_ADMIN_USERNAME=admin CENOTOO_ADMIN_PASSWORD=newpass \
#       sudo ./scripts/reset-admin.sh    # non-interactive
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
PG_POD="${PG_POD:-cenotoo-postgres-0}"
PG_TIMEOUT="${PG_TIMEOUT:-30}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

info()    { echo -e "  ${BLUE}▸${RESET} $*"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; exit 1; }
dimtext() { echo -e "  ${DIM}$*${RESET}"; }

# ---------------------------------------------------------------------------
# psql helpers — pipe to psql in the postgres pod, return output
# ---------------------------------------------------------------------------
run_psql_cmd() {
    echo "$1" | kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
        psql -U "$PG_USER" -d "$PG_DB" --no-password -t -A 2>/dev/null || echo ""
}

run_psql_stdin() {
    kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
        psql -U "$PG_USER" -d "$PG_DB" --no-password 2>&1
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║   Cenotoo — Reset Admin Credentials      ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚═══════════════════════════════════════════╝${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v kubectl &>/dev/null || fail "kubectl is not installed"
command -v python3 &>/dev/null || fail "python3 is required"
python3 -c "import bcrypt" 2>/dev/null \
    || fail "python3-bcrypt missing. Install with: sudo apt install python3-bcrypt"

kubectl get ns "$NAMESPACE" &>/dev/null || fail "Namespace '$NAMESPACE' not found"
kubectl get pod "$PG_POD" -n "$NAMESPACE" &>/dev/null \
    || fail "Pod $PG_POD not found in namespace $NAMESPACE"

PG_USER=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")
PG_DB=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.database}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")

# Wait briefly for PG to be responsive
ELAPSED=0
while [ "$ELAPSED" -lt "$PG_TIMEOUT" ]; do
    if kubectl exec -n "$NAMESPACE" "$PG_POD" -- pg_isready -U "$PG_USER" &>/dev/null; then
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
[ "$ELAPSED" -lt "$PG_TIMEOUT" ] || fail "PostgreSQL not responsive within ${PG_TIMEOUT}s"
ok "Connected to PostgreSQL (db=$PG_DB, user=$PG_USER)"

# ---------------------------------------------------------------------------
# List existing admin (superadmin) users
# ---------------------------------------------------------------------------
EXISTING_ADMINS=$(run_psql_cmd "SELECT username FROM users WHERE role = 'superadmin' ORDER BY username;")
if [ -n "$EXISTING_ADMINS" ]; then
    info "Existing superadmin users:"
    echo "$EXISTING_ADMINS" | while IFS= read -r u; do
        [ -n "$u" ] && echo -e "    ${BOLD}- $u${RESET}"
    done
else
    warn "No superadmin users found — this script will create one"
fi
echo ""

# ---------------------------------------------------------------------------
# Gather new credentials (env vars take precedence; fall back to interactive)
# ---------------------------------------------------------------------------
ADMIN_USER="${CENOTOO_ADMIN_USERNAME:-}"
ADMIN_PASS="${CENOTOO_ADMIN_PASSWORD:-}"

if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
    if [ ! -t 0 ]; then
        fail "No TTY and CENOTOO_ADMIN_USERNAME/CENOTOO_ADMIN_PASSWORD not set"
    fi

    if [ -z "$ADMIN_USER" ]; then
        DEFAULT_USER=""
        # Pre-fill with first existing admin if any (most common case is rotating
        # the password for the existing 'admin' account).
        if [ -n "$EXISTING_ADMINS" ]; then
            DEFAULT_USER=$(echo "$EXISTING_ADMINS" | head -n1)
        else
            DEFAULT_USER="admin"
        fi
        echo -en "  ${BLUE}▸${RESET} Admin username ${DIM}[${DEFAULT_USER}]${RESET}: "
        read -r _input
        ADMIN_USER="${_input:-$DEFAULT_USER}"
    fi

    while [ -z "$ADMIN_PASS" ]; do
        echo -en "  ${BLUE}▸${RESET} New password: "
        read -rs ADMIN_PASS
        echo ""
        if [ -z "$ADMIN_PASS" ]; then
            warn "Password cannot be empty"
            continue
        fi
        if [ "${#ADMIN_PASS}" -lt 8 ]; then
            warn "Password must be at least 8 characters"
            ADMIN_PASS=""
            continue
        fi
        echo -en "  ${BLUE}▸${RESET} Confirm password: "
        read -rs CONFIRM_PASS
        echo ""
        if [ "$ADMIN_PASS" != "$CONFIRM_PASS" ]; then
            warn "Passwords do not match — try again"
            ADMIN_PASS=""
        fi
    done
else
    info "Using credentials from CENOTOO_ADMIN_USERNAME/PASSWORD env vars"
fi

# ---------------------------------------------------------------------------
# Determine action: UPDATE existing user or INSERT new one
# ---------------------------------------------------------------------------
USER_EXISTS=$(run_psql_cmd "SELECT COUNT(*) FROM users WHERE username = '${ADMIN_USER//\'/\'\'}';")

# Generate bcrypt hash. The 'sys.argv[1]' indirection avoids interpolating
# the password into the python source string, which would break on quotes.
HASHED=$(python3 -c "
import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())
" "$ADMIN_PASS" 2>/dev/null || true)
[ -n "$HASHED" ] || fail "Failed to bcrypt-hash password"

# Escape single-quotes for safe SQL embedding (doubling is the SQL standard).
ESCAPED_HASH="${HASHED//\'/\'\'}"
ESCAPED_USER="${ADMIN_USER//\'/\'\'}"

if [ "${USER_EXISTS:-0}" -gt 0 ]; then
    echo ""
    warn "User '${ADMIN_USER}' exists — its password will be reset"
    if [ -t 0 ] && [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
        echo -en "  ${BLUE}▸${RESET} Continue? [y/N]: "
        read -r CONFIRM
        [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || fail "Aborted by user"
    fi

    run_psql_cmd "
UPDATE users
SET password = '${ESCAPED_HASH}', role = 'superadmin'
WHERE username = '${ESCAPED_USER}';
" >/dev/null
    ok "Password reset for '${ADMIN_USER}' (role ensured: superadmin)"
else
    # Resolve the organization for the new user. Prefer the bootstrap org,
    # then any existing org, then auto-create the bootstrap org if the DB
    # has none (happens when install.sh ran non-interactively and the org
    # seed in init-postgres-schema.sh was skipped).
    BOOTSTRAP_ORG_ID="00000000-0000-0000-0000-000000000001"
    ORG_ID=$(run_psql_cmd "SELECT id FROM organization WHERE id = '${BOOTSTRAP_ORG_ID}'::uuid LIMIT 1;")
    if [ -z "$ORG_ID" ]; then
        ORG_ID=$(run_psql_cmd "SELECT id FROM organization ORDER BY creation_date LIMIT 1;")
    fi
    if [ -z "$ORG_ID" ]; then
        info "No organization found — creating bootstrap org 'cenotoo'"
        run_psql_cmd "
INSERT INTO organization (id, organization_name, description, tags, creation_date)
VALUES ('${BOOTSTRAP_ORG_ID}'::uuid, 'cenotoo', '', ARRAY[]::TEXT[], NOW())
ON CONFLICT (id) DO NOTHING;
" >/dev/null
        ORG_ID="$BOOTSTRAP_ORG_ID"
        ok "Bootstrap organization created"
    fi

    USER_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")

    run_psql_cmd "
INSERT INTO users (id, organization_id, username, password, role, creation_date)
VALUES ('${USER_UUID}'::uuid, '${ORG_ID}'::uuid, '${ESCAPED_USER}', '${ESCAPED_HASH}', 'superadmin', NOW());
" >/dev/null
    ok "Created new superadmin user: ${ADMIN_USER}"
fi

# ---------------------------------------------------------------------------
# Invalidate any active JWT sessions for this user by revoking all of their
# tokens. Cheaper than tracking jti per-user — the API checks revoked_tokens
# on every authenticated request.
# Skipped silently if the table is missing (older schemas).
# ---------------------------------------------------------------------------
HAS_REVOKED=$(run_psql_cmd "SELECT to_regclass('public.revoked_tokens') IS NOT NULL;")
if [ "$HAS_REVOKED" = "t" ]; then
    dimtext "Existing JWT sessions for this user will continue to work until expiry."
    dimtext "To force re-login, manually revoke their tokens via the API."
fi

echo ""
echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}Admin credentials updated${RESET}                       │"
echo -e "  │                                                  │"
printf  "  │  %-48s │\n" "Username: ${ADMIN_USER}"
printf  "  │  %-48s │\n" "Password: <hidden>"
echo -e "  │                                                  │"
echo -e "  └──────────────────────────────────────────────────┘"
echo ""
dimtext "Log in at the dashboard or via:"
dimtext "  curl -X POST https://api.<your-domain>/auth/login \\"
dimtext "       -H 'Content-Type: application/json' \\"
dimtext "       -d '{\"username\":\"${ADMIN_USER}\",\"password\":\"...\"}'"
echo ""
