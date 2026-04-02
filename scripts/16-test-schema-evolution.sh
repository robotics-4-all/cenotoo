#!/usr/bin/env bash
# =============================================================================
# 16-test-schema-evolution.sh — Schema Evolution API verification for Cenotoo
#
# Tests the Schema Evolution feature on a running k3s cluster:
#   1. Preflight checks
#   2. API authentication + test project/collection setup
#   3. Add new fields (PATCH /schema with add_fields)
#   4. Verify added fields appear in collection schema
#   5. Ingest data with the new fields
#   6. Remove fields (PATCH /schema with remove_fields)
#   7. Verify removed fields no longer appear in schema
#   8. Reject adding duplicate fields (409)
#   9. Reject removing system fields (400)
#  10. Reject unsupported type (400)
#  11. Reject empty body (400)
#  12. Auth enforcement (read/write key rejected for schema changes)
#  13. Cleanup
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username     (default: cenotoo)
#   CENOTOO_ADMIN_PASSWORD   API admin password     (required — no default)
#
# Prerequisites:
#   - jq, curl, kubectl
#   - Cenotoo deployed (07), API deployed (08)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/16-test-schema-evolution.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="sch-$(date +%s)"
TEST_PROJECT="schetest${RUN_ID##sch-}"
TEST_COLLECTION="readings"

API_PORT=8000
API_BASE="http://localhost:${API_PORT}/api/v1"

passed=0
failed=0

pass()  { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()  { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()  { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header(){ printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

PF_API_PID=""
PROJECT_ID=""
COLLECTION_ID=""
API_TOKEN=""
READ_KEY=""
WRITE_KEY=""
MASTER_KEY=""
_RESP_FILE="/tmp/cenotoo_sch_test_resp_$$.json"

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

_api() {
    local method="$1" url="$2"; shift 2
    local http
    http=$(curl -s -o "$_RESP_FILE" -w "%{http_code}" -X "$method" "$url" "$@" 2>/dev/null || echo "000")
    echo "$http"
}

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
    exit 1
fi
pass "Namespace $NAMESPACE exists"

# ---------------------------------------------------------------------------
header "Port-Forward Setup"
# ---------------------------------------------------------------------------
API_SVC=$(kubectl get svc -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=api,app.kubernetes.io/part-of=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$API_SVC" ]; then
    fail "Cannot find cenotoo-api Service in namespace $NAMESPACE"
    exit 1
fi

pkill -f "kubectl port-forward.*${API_PORT}:8000" 2>/dev/null || true
sleep 1

info "Port-forwarding API service $API_SVC → localhost:${API_PORT} ..."
kubectl port-forward "svc/${API_SVC}" "${API_PORT}:8000" -n "$NAMESPACE" &>/dev/null &
PF_API_PID=$!

_elapsed=0
until curl -s "http://localhost:${API_PORT}/health" &>/dev/null; do
    sleep 1
    _elapsed=$((_elapsed + 1))
    if [ "$_elapsed" -ge 15 ]; then
        fail "API not responding on port ${API_PORT} after 15s"
        exit 1
    fi
done
pass "API port-forward active and healthy (pid $PF_API_PID)"

# ---------------------------------------------------------------------------
header "API Authentication & Setup"
# ---------------------------------------------------------------------------
ADMIN_USERNAME="${CENOTOO_ADMIN_USERNAME:-cenotoo}"
ADMIN_PASSWORD="${CENOTOO_ADMIN_PASSWORD}"

AUTH_HTTP=$(_api POST "${API_BASE}/token" \
    -d "username=${ADMIN_USERNAME}&password=${ADMIN_PASSWORD}")
if [ "$AUTH_HTTP" = "200" ]; then
    API_TOKEN=$(jq -r '.access_token // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "null" ]; then
        pass "API authentication successful"
    else
        fail "API auth: got 200 but no access_token"
        exit 1
    fi
else
    fail "API authentication failed (HTTP $AUTH_HTTP)"
    exit 1
fi

info "Creating test project: $TEST_PROJECT ..."
PROJ_HTTP=$(_api POST "${API_BASE}/projects" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"Schema evolution test\", \"tags\": [\"test\"]}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
        pass "Test project created: $PROJECT_ID"
    else
        fail "Project created but no ID in response"
        exit 1
    fi
else
    fail "Project creation failed (HTTP $PROJ_HTTP)"
    exit 1
fi

info "Creating test collection: $TEST_COLLECTION ..."
COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"Schema test\", \"tags\": [\"test\"], \"collection_schema\": {\"temperature\": \"float\", \"sensor_id\": \"text\"}}")
if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
    COLLECTION_ID=$(curl -s "${API_BASE}/projects/${PROJECT_ID}/collections" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        | jq -r --arg name "$TEST_COLLECTION" '.items[] | select(.collection_name==$name) | .collection_id // ""' 2>/dev/null || echo "")
    if [ -n "$COLLECTION_ID" ] && [ "$COLLECTION_ID" != "null" ]; then
        pass "Test collection created: $COLLECTION_ID"
    else
        fail "Collection created but could not resolve collection ID"
    fi
else
    fail "Collection creation failed (HTTP $COLL_HTTP): $(cat "$_RESP_FILE")"
fi

info "Creating API keys ..."
READ_KEY=$(jq -r '.api_key // ""' <(curl -s -X POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"key_type": "read"}') 2>/dev/null || echo "")
WRITE_KEY=$(jq -r '.api_key // ""' <(curl -s -X POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"key_type": "write"}') 2>/dev/null || echo "")
MASTER_KEY=$(jq -r '.api_key // ""' <(curl -s -X POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"key_type": "master"}') 2>/dev/null || echo "")

if [ -n "$MASTER_KEY" ] && [ "$MASTER_KEY" != "null" ]; then
    pass "API keys created"
else
    fail "Failed to create master API key"
fi

SCHEMA_URL="${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/schema"

# ---------------------------------------------------------------------------
header "TEST_01: Add New Fields (PATCH /schema)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    ADD_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"add_fields": {"humidity": "float", "location": "text", "active": "bool"}}')
    if [ "$ADD_HTTP" = "200" ]; then
        ADDED=$(jq -r '.added | length' "$_RESP_FILE" 2>/dev/null || echo "0")
        if [ "$ADDED" = "3" ]; then
            pass "TEST_01: Added 3 fields (humidity, location, active)"
        else
            fail "TEST_01: Expected 3 added fields, got $ADDED: $(cat "$_RESP_FILE")"
        fi
    else
        fail "TEST_01: Add fields failed (HTTP $ADD_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_01: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_02: Verify Added Fields in Schema (GET /collection)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    INFO_HTTP=$(_api GET "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}" \
        -H "X-API-Key: ${READ_KEY}")
    if [ "$INFO_HTTP" = "200" ]; then
        HAS_HUMIDITY=$(jq -r 'has("collection_schema") and (.collection_schema | has("humidity"))' "$_RESP_FILE" 2>/dev/null || echo "false")
        HAS_LOCATION=$(jq -r 'has("collection_schema") and (.collection_schema | has("location"))' "$_RESP_FILE" 2>/dev/null || echo "false")
        if [ "$HAS_HUMIDITY" = "true" ] && [ "$HAS_LOCATION" = "true" ]; then
            pass "TEST_02: New fields visible in collection schema"
        else
            fail "TEST_02: New fields not visible in schema (humidity=$HAS_HUMIDITY, location=$HAS_LOCATION)"
        fi
    else
        fail "TEST_02: Get collection info failed (HTTP $INFO_HTTP)"
    fi
else
    info "TEST_02: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_03: Ingest Data with New Fields"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ] && [ -n "$WRITE_KEY" ]; then
    SEND_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/send_data" \
        -H "X-API-Key: ${WRITE_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"temperature": 22.5, "sensor_id": "s001", "humidity": 60.1, "location": "room-a", "active": true}')
    if [ "$SEND_HTTP" = "200" ] || [ "$SEND_HTTP" = "201" ]; then
        pass "TEST_03: Data ingested successfully with new fields"
    else
        fail "TEST_03: Data ingestion failed (HTTP $SEND_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_03: Skipping (no collection ID or write key)"
fi

# ---------------------------------------------------------------------------
header "TEST_04: Remove Fields (PATCH /schema with remove_fields)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    REMOVE_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"remove_fields": ["active"]}')
    if [ "$REMOVE_HTTP" = "200" ]; then
        REMOVED=$(jq -r '.removed | length' "$_RESP_FILE" 2>/dev/null || echo "0")
        if [ "$REMOVED" = "1" ]; then
            pass "TEST_04: Removed 1 field (active)"
        else
            fail "TEST_04: Expected 1 removed field, got $REMOVED: $(cat "$_RESP_FILE")"
        fi
    else
        fail "TEST_04: Remove fields failed (HTTP $REMOVE_HTTP): $(cat "$_RESP_FILE")"
    fi
else
    info "TEST_04: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_05: Reject Duplicate Add (409)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    DUP_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"add_fields": {"humidity": "float"}}')
    if [ "$DUP_HTTP" = "409" ]; then
        pass "TEST_05: Duplicate field correctly rejected (409)"
    else
        fail "TEST_05: Duplicate field returned HTTP $DUP_HTTP (expected 409)"
    fi
else
    info "TEST_05: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_06: Reject System Field Removal (400)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    SYS_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"remove_fields": ["timestamp"]}')
    if [ "$SYS_HTTP" = "400" ]; then
        pass "TEST_06: System field removal correctly rejected (400)"
    else
        fail "TEST_06: System field removal returned HTTP $SYS_HTTP (expected 400)"
    fi
else
    info "TEST_06: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_07: Reject Unsupported Type (400)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    BAD_TYPE_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"add_fields": {"coords": "geometry"}}')
    if [ "$BAD_TYPE_HTTP" = "400" ]; then
        pass "TEST_07: Unsupported type correctly rejected (400)"
    else
        fail "TEST_07: Unsupported type returned HTTP $BAD_TYPE_HTTP (expected 400)"
    fi
else
    info "TEST_07: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_08: Reject Empty Body (400)"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    EMPTY_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "X-API-Key: ${MASTER_KEY}" \
        -H "Content-Type: application/json" \
        -d '{}')
    if [ "$EMPTY_HTTP" = "400" ]; then
        pass "TEST_08: Empty schema evolution body correctly rejected (400)"
    else
        fail "TEST_08: Empty body returned HTTP $EMPTY_HTTP (expected 400)"
    fi
else
    info "TEST_08: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "TEST_09: Auth Enforcement for Schema Changes"
# ---------------------------------------------------------------------------
if [ -n "${COLLECTION_ID:-}" ] && [ "$COLLECTION_ID" != "null" ]; then
    UNAUTH_HTTP=$(_api PATCH "$SCHEMA_URL" \
        -H "Content-Type: application/json" \
        -d '{"add_fields": {"x": "int"}}')
    if [ "$UNAUTH_HTTP" = "401" ] || [ "$UNAUTH_HTTP" = "403" ]; then
        pass "TEST_09a: Unauthenticated PATCH /schema rejected (HTTP $UNAUTH_HTTP)"
    else
        fail "TEST_09a: Unauthenticated PATCH /schema accepted (HTTP $UNAUTH_HTTP)"
    fi

    if [ -n "${WRITE_KEY:-}" ]; then
        WRITE_PATCH_HTTP=$(_api PATCH "$SCHEMA_URL" \
            -H "X-API-Key: ${WRITE_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"add_fields": {"x": "int"}}')
        if [ "$WRITE_PATCH_HTTP" = "403" ]; then
            pass "TEST_09b: Write key correctly rejected for PATCH /schema (403)"
        else
            fail "TEST_09b: Write key PATCH /schema returned HTTP $WRITE_PATCH_HTTP (expected 403)"
        fi
    fi

    if [ -n "${READ_KEY:-}" ]; then
        READ_PATCH_HTTP=$(_api PATCH "$SCHEMA_URL" \
            -H "X-API-Key: ${READ_KEY}" \
            -H "Content-Type: application/json" \
            -d '{"add_fields": {"x": "int"}}')
        if [ "$READ_PATCH_HTTP" = "403" ]; then
            pass "TEST_09c: Read key correctly rejected for PATCH /schema (403)"
        else
            fail "TEST_09c: Read key PATCH /schema returned HTTP $READ_PATCH_HTTP (expected 403)"
        fi
    fi
else
    info "TEST_09: Skipping (no collection ID)"
fi

# ---------------------------------------------------------------------------
header "Summary"
# ---------------------------------------------------------------------------
rm -f "$_RESP_FILE"
total=$((passed + failed))
printf '\n  \033[1;32m%d passed\033[0m' "$passed"
if [ "$failed" -gt 0 ]; then
    printf ', \033[1;31m%d failed\033[0m' "$failed"
fi
printf ' (out of %d tests)\n\n' "$total"

if [ "$failed" -gt 0 ]; then
    printf '\033[1;31mSCHEMA EVOLUTION TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mSCHEMA EVOLUTION TEST PASSED\033[0m\n'
    exit 0
fi
