#!/usr/bin/env bash
# =============================================================================
# init-cassandra-schema.sh — Initialize Cassandra metadata keyspace and tables
# =============================================================================
# Creates the metadata keyspace and all API tables (user, organization,
# project, collection, api_keys, revoked_tokens).
#
# Safe to re-run — all statements use IF NOT EXISTS.
#
# Called automatically by 07-deploy-cenotoo.sh, or run standalone:
#   sudo ./scripts/init-cassandra-schema.sh
# =============================================================================
set -euo pipefail

NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
CASSANDRA_POD="${CASSANDRA_POD:-cenotoo-cassandra-0}"
CASSANDRA_DC="${CASSANDRA_DC:-dc1}"
CASSANDRA_RF="${CASSANDRA_RF:-1}"
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
CASSANDRA_PASS="${CASSANDRA_PASS:-cassandra}"
CQL_TIMEOUT="${CQL_TIMEOUT:-120}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

run_cql() {
    kubectl exec -i -n "$NAMESPACE" "$CASSANDRA_POD" -- \
        cqlsh -u "$CASSANDRA_USER" -p "$CASSANDRA_PASS" 2>&1
}

wait_for_cql() {
    local elapsed=0
    info "Waiting for CQL to be responsive on $CASSANDRA_POD ..."
    while [ "$elapsed" -lt "$CQL_TIMEOUT" ]; do
        if echo "DESCRIBE KEYSPACES;" | run_cql &>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "CQL not responsive on $CASSANDRA_POD within ${CQL_TIMEOUT}s"
}

info "Initializing Cassandra schema (namespace=$NAMESPACE, rf=$CASSANDRA_RF)"

wait_for_cql
ok "CQL is responsive"

info "Applying schema (keyspace + 6 tables) ..."

run_cql <<EOF
CREATE KEYSPACE IF NOT EXISTS metadata
    WITH REPLICATION = {'class': 'NetworkTopologyStrategy', '$CASSANDRA_DC': $CASSANDRA_RF};

CREATE TABLE IF NOT EXISTS metadata.user (
    id UUID PRIMARY KEY,
    username TEXT,
    password TEXT,
    role TEXT,
    organization_id UUID
);

CREATE TABLE IF NOT EXISTS metadata.organization (
    id UUID PRIMARY KEY,
    organization_name TEXT,
    description TEXT,
    creation_date TIMESTAMP,
    tags LIST<TEXT>
);

CREATE TABLE IF NOT EXISTS metadata.project (
    id UUID PRIMARY KEY,
    organization_id UUID,
    project_name TEXT,
    description TEXT,
    creation_date TIMESTAMP,
    tags LIST<TEXT>
);

CREATE TABLE IF NOT EXISTS metadata.collection (
    id UUID PRIMARY KEY,
    organization_id UUID,
    project_id UUID,
    collection_name TEXT,
    description TEXT,
    creation_date TIMESTAMP,
    tags LIST<TEXT>
);

CREATE TABLE IF NOT EXISTS metadata.api_keys (
    id UUID PRIMARY KEY,
    project_id UUID,
    key_type TEXT,
    api_key TEXT,
    created_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS metadata.revoked_tokens (
    jti TEXT PRIMARY KEY,
    revoked_at TIMESTAMP,
    expires_at TIMESTAMP
);
EOF

ok "Schema applied"

info "Verifying ..."
TABLES=$(echo "SELECT table_name FROM system_schema.tables WHERE keyspace_name='metadata';" | run_cql)
EXPECTED=("user" "organization" "project" "collection" "api_keys" "revoked_tokens")
for tbl in "${EXPECTED[@]}"; do
    if echo "$TABLES" | grep -q "$tbl"; then
        ok "Verified: metadata.$tbl"
    else
        fail "Missing table: metadata.$tbl"
    fi
done

info "Seeding admin user ..."

EXISTING=$(echo "SELECT id FROM metadata.user LIMIT 1 ALLOW FILTERING;" | run_cql 2>/dev/null || echo "")
if ! echo "$EXISTING" | grep -q "(0 rows)"; then
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

    ORG_ID="00000000-0000-0000-0000-000000000001"
    ADMIN_UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
    HASHED=$(python3 -c "
import bcrypt, sys
h = bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode()
print(h)
" "$ADMIN_PASS" 2>/dev/null)

    if [ -n "$HASHED" ] && [ -n "$ADMIN_UUID" ]; then
        printf "INSERT INTO metadata.user (id, organization_id, username, password, role) VALUES (%s, %s, '%s', '%s', 'superadmin');\n" \
            "$ADMIN_UUID" "$ORG_ID" "$ADMIN_USER" "$HASHED" | run_cql
        ok "Admin user created: $ADMIN_USER (role: superadmin)"
    else
        warn "Python bcrypt not available — install with: pip install bcrypt"
        warn "Then re-run this script to seed the admin user"
    fi
fi

echo ""
ok "Cassandra schema initialization complete"
