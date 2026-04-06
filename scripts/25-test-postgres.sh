#!/usr/bin/env bash
# =============================================================================
# 25-test-postgres.sh — End-to-end PostgreSQL verification for Cenotoo
#
# Tests the full PostgreSQL metadata layer on a running k3s cluster:
#   1. Pod/StatefulSet health (cenotoo-postgres)
#   2. Database connectivity (pg_isready + psql ping)
#   3. Schema verification (all 10 expected tables present)
#   4. API-level CRUD via port-forward: project → collection → read back
#   5. API key creation and authentication via API key header
#   6. Auth rejection — invalid credentials
#   7. PostgreSQL log health (no ERROR/FATAL in recent logs)
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username  (default: cenotoo)
#   CENOTOO_ADMIN_PASSWORD   API admin password  (required — no default)
#
# Prerequisites:
#   - jq, curl, kubectl
#   - Cenotoo deployed (07), PostgreSQL deployed (24), API deployed (08)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/25-test-postgres.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="pgtest-$(date +%s)"
TEST_PROJECT="pgtest${RUN_ID##pgtest-}"
TEST_COLLECTION="sensors"

API_PORT=8000
API_BASE="http://localhost:${API_PORT}/api/v1"

PG_POD="cenotoo-postgres-0"
PG_STATEFULSET="cenotoo-postgres"

passed=0
failed=0

pass()   { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()   { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()   { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header() { printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

PF_API_PID=""
PF_OK=0
PROJECT_ID=""
API_TOKEN=""
_RESP_FILE="/tmp/cenotoo_pg_test_resp_$$.json"

cleanup() {
    info "Cleaning up ..."
    if [ -n "${PROJECT_ID:-}" ] && [ -n "${API_TOKEN:-}" ]; then
        curl -s -X DELETE \
            "${API_BASE}/projects/${PROJECT_ID}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            >/dev/null 2>&1 || true
        info "Deleted test project $PROJECT_ID"
    fi
    [ -n "${PF_API_PID:-}" ] && kill "$PF_API_PID" 2>/dev/null || true
    rm -f "$_RESP_FILE" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# run_psql_cmd <sql> — run a single SQL statement in the postgres pod
# ---------------------------------------------------------------------------
run_psql_cmd() {
    local sql="$1"
    local pg_user
    pg_user=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")
    local pg_db
    pg_db=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
        -o jsonpath='{.data.database}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")
    echo "$sql" | kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
        psql -U "$pg_user" -d "$pg_db" --no-password -t -A 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# _api <method> <url> [curl-args...] — curl helper, returns HTTP status code
# ---------------------------------------------------------------------------
_api() {
    local method="$1" url="$2"; shift 2
    local http
    http=$(curl -s -o "$_RESP_FILE" -w "%{http_code}" -X "$method" "$url" "$@" 2>/dev/null || echo "000")
    echo "$http"
}

# ---------------------------------------------------------------------------
printf '\n\033[1;36m\033[1m'
printf '  ╔══════════════════════════════════════════════════╗\n'
printf '  ║   Cenotoo PostgreSQL — Integration Tests        ║\n'
printf '  ╚══════════════════════════════════════════════════╝\n'
printf '\033[0m\n'
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
header "Preflight"
# ---------------------------------------------------------------------------
for cmd in jq curl kubectl; do
    if command -v "$cmd" &>/dev/null; then
        pass "Command available: $cmd"
    else
        fail "Command not found: $cmd"
    fi
done

if [ -z "${CENOTOO_ADMIN_PASSWORD:-}" ]; then
    fail "CENOTOO_ADMIN_PASSWORD is not set"
    printf '\n\033[1;31mRun: CENOTOO_ADMIN_PASSWORD=<pass> %s\033[0m\n' "$0"
    exit 1
fi
pass "CENOTOO_ADMIN_PASSWORD is set"

if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    fail "Namespace $NAMESPACE not found"
    printf '\n\033[1;31mCannot run PostgreSQL tests without the cenotoo namespace. Exiting.\033[0m\n'
    exit 1
fi
pass "Namespace $NAMESPACE exists"

# ---------------------------------------------------------------------------
header "Pod Health"
# ---------------------------------------------------------------------------
PG_PHASE=$(kubectl get pod "$PG_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
PG_READY=$(kubectl get pod "$PG_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

if [ "$PG_PHASE" = "Running" ] && [ "$PG_READY" = "True" ]; then
    pass "Pod $PG_POD is Running and Ready"
else
    fail "Pod $PG_POD is not Ready (phase: ${PG_PHASE:-Unknown}, ready: ${PG_READY:-Unknown})"
    printf '\n\033[1;31mCannot run PostgreSQL tests without a ready pod. Exiting.\033[0m\n'
    exit 1
fi

SS_READY=$(kubectl get statefulset "$PG_STATEFULSET" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
SS_DESIRED=$(kubectl get statefulset "$PG_STATEFULSET" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
if [ "${SS_READY:-0}" = "$SS_DESIRED" ] && [ "$SS_DESIRED" != "0" ]; then
    pass "StatefulSet $PG_STATEFULSET: ${SS_READY}/${SS_DESIRED} replicas ready"
else
    fail "StatefulSet $PG_STATEFULSET: ${SS_READY:-0}/${SS_DESIRED} replicas ready"
fi

PG_RESTARTS=$(kubectl get pod "$PG_POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [ "${PG_RESTARTS:-0}" -lt 5 ]; then
    pass "Pod restart count: ${PG_RESTARTS:-0} (healthy)"
else
    fail "Pod restart count: $PG_RESTARTS (possible crash loop)"
fi

# ---------------------------------------------------------------------------
header "Database Connectivity"
# ---------------------------------------------------------------------------
PG_USER=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")
PG_DB=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
    -o jsonpath='{.data.database}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")

if kubectl exec -n "$NAMESPACE" "$PG_POD" -- pg_isready -U "$PG_USER" &>/dev/null; then
    pass "pg_isready: PostgreSQL accepting connections"
else
    fail "pg_isready: PostgreSQL not accepting connections"
fi

PING=$(run_psql_cmd "SELECT 1;")
if [ "${PING:-}" = "1" ]; then
    pass "psql ping: SELECT 1 returned 1"
else
    fail "psql ping: SELECT 1 failed (got: '${PING:-error}')"
fi

PG_VERSION=$(run_psql_cmd "SELECT version();" 2>/dev/null | head -1 || echo "")
if [ -n "$PG_VERSION" ]; then
    pass "PostgreSQL version: $(echo "$PG_VERSION" | cut -c1-60)"
else
    fail "Could not retrieve PostgreSQL version"
fi

# ---------------------------------------------------------------------------
header "Schema Verification"
# ---------------------------------------------------------------------------
EXPECTED_TABLES=(
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

for tbl in "${EXPECTED_TABLES[@]}"; do
    EXISTS=$(run_psql_cmd \
        "SELECT to_regclass('public.${tbl}') IS NOT NULL;")
    if [ "$EXISTS" = "t" ]; then
        pass "Table exists: $tbl"
    else
        fail "Table missing: $tbl"
    fi
done

# Verify pgcrypto extension (required for gen_random_uuid)
EXT=$(run_psql_cmd \
    "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pgcrypto';")
if [ "${EXT:-0}" -gt 0 ]; then
    pass "Extension pgcrypto is installed"
else
    fail "Extension pgcrypto is missing"
fi

# ---------------------------------------------------------------------------
header "Port-Forward Setup"
# ---------------------------------------------------------------------------
API_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$API_SVC" ]; then
    fail "Cannot find cenotoo-api Service in namespace $NAMESPACE"
    printf '\n\033[1;31mCannot run API-level tests without the API service. Skipping remaining tests.\033[0m\n'
    # Still print summary and exit
    total=$((passed + failed))
    printf '\n  \033[1;32m%d passed\033[0m' "$passed"
    [ "$failed" -gt 0 ] && printf ', \033[1;31m%d failed\033[0m' "$failed"
    printf ' (out of %d tests)\n\n' "$total"
    [ "$failed" -gt 0 ] && exit 1 || exit 0
fi

info "Port-forwarding $API_SVC → localhost:${API_PORT} ..."
kubectl port-forward "svc/${API_SVC}" "${API_PORT}:8000" -n "$NAMESPACE" &>/dev/null &
PF_API_PID=$!
sleep 3

if kill -0 "$PF_API_PID" 2>/dev/null; then
    pass "API port-forward active (pid $PF_API_PID)"
    PF_OK=1
else
    fail "API port-forward failed — skipping API-level tests"
    PF_API_PID=""
fi

# ---------------------------------------------------------------------------
header "API Authentication"
# ---------------------------------------------------------------------------
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-cenotoo}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD}"

if [ "$PF_OK" -eq 0 ]; then
    info "Skipping (no API port-forward)"
fi

if [ "$PF_OK" -eq 1 ]; then
info "Authenticating as $ADMIN_USERNAME ..."
AUTH_HTTP=$(_api POST "${API_BASE}/token" \
    -d "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}")
if [ "$AUTH_HTTP" = "200" ]; then
    API_TOKEN=$(jq -r '.access_token // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "null" ]; then
        pass "API authentication successful"
    else
        fail "API auth: got 200 but no access_token in response"
        API_TOKEN=""
    fi
else
    fail "API authentication failed (HTTP $AUTH_HTTP) — check CENOTOO_ADMIN_USERNAME ($ADMIN_USERNAME) and CENOTOO_ADMIN_PASSWORD"
fi

# Test auth rejection with invalid credentials
info "Testing auth rejection with invalid credentials ..."
BAD_HTTP=$(_api POST "${API_BASE}/token" \
    -d "username=nobody&password=wrongpassword")
if [ "$BAD_HTTP" = "401" ] || [ "$BAD_HTTP" = "400" ] || [ "$BAD_HTTP" = "403" ]; then
    pass "Auth rejection: invalid credentials correctly rejected (HTTP $BAD_HTTP)"
else
    fail "Auth rejection: expected 4xx for bad credentials, got HTTP $BAD_HTTP"
fi
fi  # PF_OK

# ---------------------------------------------------------------------------
header "API CRUD — Project & Collection"
# ---------------------------------------------------------------------------
if [ "$PF_OK" -eq 0 ]; then
    info "Skipping (no API port-forward)"
fi
if [ "$PF_OK" -eq 1 ] && [ -n "${API_TOKEN:-}" ]; then
    info "Creating test project: $TEST_PROJECT ..."
    PROJ_HTTP=$(_api POST "${API_BASE}/projects" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"PostgreSQL integration test\", \"tags\": [\"test\"]}")
    if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
        PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
            pass "Project created in PostgreSQL: $PROJECT_ID"
        else
            fail "Project created (HTTP $PROJ_HTTP) but no ID in response: $(cat "$_RESP_FILE")"
        fi
    else
        fail "Project creation failed (HTTP $PROJ_HTTP): $(cat "$_RESP_FILE")"
    fi
fi

if [ "$PF_OK" -eq 1 ] && [ -n "${PROJECT_ID:-}" ]; then
    PG_PROJECT=$(run_psql_cmd \
        "SELECT id FROM project WHERE id = '${PROJECT_ID}'::uuid;")
    if [ "${PG_PROJECT:-}" = "$PROJECT_ID" ]; then
        pass "Project round-trip: found in PostgreSQL (id=$PROJECT_ID)"
    else
        fail "Project round-trip: not found in PostgreSQL (id=$PROJECT_ID)"
    fi
fi

COLLECTION_ID=""
if [ "$PF_OK" -eq 1 ] && [ -n "${PROJECT_ID:-}" ]; then
    info "Creating test collection: $TEST_COLLECTION ..."
    COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"PG test\", \"tags\": [\"test\"], \"collection_schema\": {\"value\": \"float\", \"sensor_id\": \"text\"}}")
    if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
        COLLECTION_ID=$(jq -r '.collection_id // .id.collection_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        pass "Collection created (HTTP $COLL_HTTP)"
    else
        fail "Collection creation failed (HTTP $COLL_HTTP): $(cat "$_RESP_FILE")"
    fi
fi

if [ "$PF_OK" -eq 1 ] && [ -n "${COLLECTION_ID:-}" ]; then
    PG_COLL=$(run_psql_cmd \
        "SELECT id FROM collection WHERE id = '${COLLECTION_ID}'::uuid;")
    if [ "${PG_COLL:-}" = "$COLLECTION_ID" ]; then
        pass "Collection round-trip: found in PostgreSQL (id=$COLLECTION_ID)"
    else
        fail "Collection round-trip: not found in PostgreSQL (id=$COLLECTION_ID)"
    fi
fi

# ---------------------------------------------------------------------------
header "API Key Authentication"
# ---------------------------------------------------------------------------
WRITE_KEY=""
if [ "$PF_OK" -eq 0 ]; then
    info "Skipping (no API port-forward)"
fi
if [ "$PF_OK" -eq 1 ] && [ -n "${PROJECT_ID:-}" ]; then
    info "Creating write API key for project $PROJECT_ID ..."
    KEY_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"key_type": "write"}')
    if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
        WRITE_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")
        if [ -n "$WRITE_KEY" ] && [ "$WRITE_KEY" != "null" ]; then
            pass "Write API key created (${#WRITE_KEY} chars)"
        else
            fail "Key created (HTTP $KEY_HTTP) but no api_key in response"
        fi
    else
        fail "API key creation failed (HTTP $KEY_HTTP): $(cat "$_RESP_FILE")"
    fi
fi

if [ "$PF_OK" -eq 1 ] && [ -n "${WRITE_KEY:-}" ] && [ -n "${PROJECT_ID:-}" ]; then
    PG_KEY_COUNT=$(run_psql_cmd \
        "SELECT COUNT(*) FROM api_keys WHERE project_id = '${PROJECT_ID}'::uuid;")
    if [ "${PG_KEY_COUNT:-0}" -gt 0 ]; then
        pass "API key round-trip: found in PostgreSQL ($PG_KEY_COUNT key(s) for project)"
    else
        fail "API key round-trip: no keys found in PostgreSQL for project $PROJECT_ID"
    fi
fi

if [ "$PF_OK" -eq 1 ] && [ -n "${WRITE_KEY:-}" ] && [ -n "${PROJECT_ID:-}" ] && [ -n "${COLLECTION_ID:-}" ]; then
    info "Ingesting test record via API key auth ..."
    INGEST_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/send_data" \
        -H "X-API-Key: ${WRITE_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"value\": 42.0, \"sensor_id\": \"${RUN_ID}\"}")
    if [ "$INGEST_HTTP" = "200" ] || [ "$INGEST_HTTP" = "201" ] || [ "$INGEST_HTTP" = "202" ]; then
        pass "API key auth: data ingested successfully (HTTP $INGEST_HTTP)"
    else
        fail "API key auth: data ingestion failed (HTTP $INGEST_HTTP)"
    fi

    # Test invalid API key rejection
    FAKE_KEY="deadbeef00000000000000000000000000000000000000000000000000000000"
    REJECT_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/send_data" \
        -H "X-API-Key: ${FAKE_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"value": 0.0}')
    if [ "$REJECT_HTTP" = "401" ] || [ "$REJECT_HTTP" = "403" ]; then
        pass "API key rejection: invalid key correctly rejected (HTTP $REJECT_HTTP)"
    else
        fail "API key rejection: expected 401/403, got HTTP $REJECT_HTTP"
    fi
fi

# ---------------------------------------------------------------------------
header "PostgreSQL Log Health"
# ---------------------------------------------------------------------------
PG_LOGS=$(kubectl logs -n "$NAMESPACE" "pod/$PG_POD" --tail=50 2>/dev/null || echo "")
PG_FATAL=$(printf '%s' "$PG_LOGS" | grep -E 'FATAL|PANIC' | grep -vcE 'shutting down|terminating connection' || true)
PG_ERRORS=$(printf '%s' "$PG_LOGS" | grep -cE '\bERROR\b' || true)
PG_STARTED=$(printf '%s' "$PG_LOGS" | grep -ci 'database system is ready to accept connections' || true)

if [ "${PG_FATAL:-0}" -eq 0 ]; then
    pass "PostgreSQL logs: no FATAL/PANIC in last 50 lines"
else
    fail "PostgreSQL logs: $PG_FATAL FATAL/PANIC message(s) in last 50 lines"
fi
if [ "${PG_ERRORS:-0}" -eq 0 ]; then
    pass "PostgreSQL logs: no ERROR messages in last 50 lines"
else
    info "PostgreSQL logs: $PG_ERRORS ERROR message(s) in last 50 lines (may be harmless)"
fi

if [ "${PG_STARTED:-0}" -gt 0 ]; then
    pass "PostgreSQL logs: startup message found (ready to accept connections)"
else
    info "PostgreSQL: no startup messages in recent 50 lines (may be old startup)"
fi

# ---------------------------------------------------------------------------
header "Summary"
# ---------------------------------------------------------------------------
total=$((passed + failed))
printf '\n  \033[1;32m%d passed\033[0m' "$passed"
if [ "$failed" -gt 0 ]; then
    printf ', \033[1;31m%d failed\033[0m' "$failed"
fi
printf ' (out of %d tests)\n\n' "$total"

if [ "$failed" -gt 0 ]; then
    printf '\033[1;31mPOSTGRESQL TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mPOSTGRESQL TEST PASSED\033[0m\n'
    exit 0
fi
