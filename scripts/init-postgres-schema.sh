#!/usr/bin/env bash
# =============================================================================
# init-postgres-schema.sh — Initialize PostgreSQL schema and seed initial data
# =============================================================================
# Applies postgres/init.sql to the running cenotoo-postgres pod and seeds
# the initial organization and admin user.
#
# Safe to re-run — all SQL statements use IF NOT EXISTS / ON CONFLICT DO NOTHING.
# The init.sql is also auto-applied on first pod boot via the
# cenotoo-postgres-init ConfigMap mounted at /docker-entrypoint-initdb.d.
# Run this script on existing clusters to ensure schema is up to date.
#
# Usage:
#   sudo ./scripts/init-postgres-schema.sh
#   CENOTOO_NAMESPACE=cenotoo ./scripts/init-postgres-schema.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
PG_POD="${PG_POD:-cenotoo-postgres-0}"
PG_TIMEOUT="${PG_TIMEOUT:-120}"
INIT_SQL="$PROJECT_DIR/postgres/init.sql"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------------------
# run_psql — pipe stdin to psql inside the postgres pod
# ---------------------------------------------------------------------------
run_psql() {
    kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
        psql -U "$PG_USER" -d "$PG_DB" --no-password 2>&1
}

# ---------------------------------------------------------------------------
# run_psql_cmd <sql> — run a single SQL command and return output
# ---------------------------------------------------------------------------
run_psql_cmd() {
    echo "$1" | kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
        psql -U "$PG_USER" -d "$PG_DB" --no-password -t -A 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# wait_for_pg — poll pg_isready until responsive
# ---------------------------------------------------------------------------
wait_for_pg() {
    local elapsed=0
    info "Waiting for PostgreSQL to be responsive on $PG_POD ..."
    while [ "$elapsed" -lt "$PG_TIMEOUT" ]; do
        if kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
                pg_isready -U "$PG_USER" &>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "PostgreSQL not responsive on $PG_POD within ${PG_TIMEOUT}s"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
info "Initializing PostgreSQL schema (namespace=$NAMESPACE, pod=$PG_POD)"

# Resolve credentials from the k8s secret
PG_USER=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")
PG_DB=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.database}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")

info "Using database: $PG_DB, user: $PG_USER"

# Verify pod exists
kubectl get pod "$PG_POD" -n "$NAMESPACE" &>/dev/null \
    || fail "Pod $PG_POD not found in namespace $NAMESPACE — run 24-deploy-postgres.sh first"

wait_for_pg
ok "PostgreSQL is responsive"

# Verify init.sql exists locally
[ -f "$INIT_SQL" ] || fail "Schema file not found: $INIT_SQL"
info "Applying schema from $INIT_SQL ..."

run_psql < "$INIT_SQL"
ok "Schema applied (10 tables)"

# ---------------------------------------------------------------------------
# Verify all expected tables exist
# ---------------------------------------------------------------------------
info "Verifying tables ..."
EXPECTED=(
    "organization"
    "project"
    "collection"
    "api_keys"
    "users"
    "revoked_tokens"
    "flink_jobs"
    "device"
    "device_shadow"
    "rules"
)

for tbl in "${EXPECTED[@]}"; do
    EXISTS=$(run_psql_cmd \
        "SELECT to_regclass('public.${tbl}') IS NOT NULL;")
    if [ "$EXISTS" = "t" ]; then
        ok "Verified: $tbl"
    else
        fail "Missing table: $tbl"
    fi
done

# ---------------------------------------------------------------------------
# Seed organization
# ---------------------------------------------------------------------------
ORG_ID="00000000-0000-0000-0000-000000000001"
info "Seeding organization ..."

EXISTING_ORG=$(run_psql_cmd \
    "SELECT COUNT(*) FROM organization WHERE id = '${ORG_ID}'::uuid;")

if [ "${EXISTING_ORG:-0}" -gt 0 ]; then
    ok "Organization already exists — skipping"
else
    echo ""
    info "No organization found. Set up the organization."
    echo ""

    printf "  Organization name [cenotoo]: "
    read -r _org_input
    ORG_NAME="${_org_input:-cenotoo}"

    run_psql_cmd "
INSERT INTO organization (id, organization_name, description, tags, creation_date)
VALUES ('${ORG_ID}'::uuid, '${ORG_NAME}', '', ARRAY[]::TEXT[], NOW())
ON CONFLICT (id) DO NOTHING;
" >/dev/null
    ok "Organization created: $ORG_NAME"
fi

# ---------------------------------------------------------------------------
# Seed admin user
# ---------------------------------------------------------------------------
info "Seeding admin user ..."
EXISTING_USER=$(run_psql_cmd \
    "SELECT COUNT(*) FROM users LIMIT 1;")

if [ "${EXISTING_USER:-0}" -gt 0 ]; then
    ok "Admin user already exists — skipping"
else
    echo ""
    info "No users found. Create the initial admin account."
    echo ""

    ADMIN_USER="admin"
    printf "  Admin username [admin]: "
    read -r _input
    ADMIN_USER="${_input:-admin}"

    ADMIN_PASS=""
    while [ -z "$ADMIN_PASS" ]; do
        printf "  Admin password: "
        read -rs ADMIN_PASS
        echo ""
        [ -z "$ADMIN_PASS" ] && warn "Password cannot be empty"
    done

    ADMIN_UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || "")
    HASHED=$(python3 -c "
import bcrypt, sys
h = bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode()
print(h)
" "$ADMIN_PASS" 2>/dev/null || echo "")

    if [ -n "$HASHED" ] && [ -n "$ADMIN_UUID" ]; then
        ESCAPED_HASH="${HASHED//\'/\'\'}"
        run_psql_cmd "
INSERT INTO users (id, organization_id, username, password, role, creation_date)
VALUES ('${ADMIN_UUID}'::uuid, '${ORG_ID}'::uuid, '${ADMIN_USER}', '${ESCAPED_HASH}', 'superadmin', NOW())
ON CONFLICT (username) DO NOTHING;
" >/dev/null
        ok "Admin user created: $ADMIN_USER (role: superadmin)"
    else
        warn "Python bcrypt not available — install with: pip install bcrypt"
        warn "Then re-run this script to seed the admin user"
    fi
fi

echo ""
ok "PostgreSQL schema initialization complete"
