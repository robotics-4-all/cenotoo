#!/usr/bin/env bash
# =============================================================================
# 21-test-statistics.sh — Statistics API verification for Cenotoo
#
# Tests the GET /statistics endpoint on a running k3s cluster:
#   1.  Preflight checks
#   2.  API authentication + test project / collection / data setup
#   3.  avg, max, min, sum, count statistics (200 + correct shape)
#   4.  Percentile stats: p50, p90, p95, p99
#   5.  distinct stat (200 + key_statistics shape)
#   6.  distinct with interval → interval_buckets populated
#   7.  Interval bucketing (interval_start present in results)
#   8.  group_by parameter (results keyed by custom field)
#   9.  Time range filtering (start_time / end_time)
#  10.  Invalid interval format → 422
#  11.  Bad attribute name → 422
#  12.  Bad group_by field → 422
#  13.  distinct without attribute → 422
#  14.  Auth enforcement (unauthenticated → 401/403, read key → 200)
#  15.  Cleanup
#
# Credentials (override via env vars):
#   CENOTOO_ADMIN_USERNAME   API admin username  (default: cenotoo)
#   CENOTOO_ADMIN_PASSWORD   API admin password  (required)
#
# Prerequisites:  jq, curl, kubectl, Cenotoo deployed (07), API deployed (08)
#
# Usage:  CENOTOO_ADMIN_PASSWORD=<pass> ./scripts/21-test-statistics.sh [NAMESPACE] [RELEASE]
# =============================================================================
set -euo pipefail

NAMESPACE="${1:-cenotoo}"
RELEASE="${2:-cenotoo}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RUN_ID="stat-$(date +%s)"
TEST_PROJECT="stattest${RUN_ID##stat-}"
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
_RESP_FILE="/tmp/cenotoo_stat_test_resp_$$.json"

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

info "Port-forwarding $API_SVC → localhost:${API_PORT} ..."
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
pass "API port-forward active (pid $PF_API_PID)"

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
        pass "Authenticated as $ADMIN_USERNAME"
    else
        fail "Auth 200 but no access_token"
        exit 1
    fi
else
    fail "Authentication failed (HTTP $AUTH_HTTP)"
    exit 1
fi

info "Creating test project: $TEST_PROJECT ..."
PROJ_HTTP=$(_api POST "${API_BASE}/projects" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"${TEST_PROJECT}\", \"description\": \"Statistics test\", \"tags\": [\"test\"]}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.project_id // .id.project_id // .id // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ] \
        && pass "Project created: $PROJECT_ID" \
        || { fail "Project created but no ID"; exit 1; }
else
    fail "Project creation failed (HTTP $PROJ_HTTP)"
    exit 1
fi

info "Creating test collection: $TEST_COLLECTION ..."
COLL_HTTP=$(_api POST "${API_BASE}/projects/${PROJECT_ID}/collections" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${TEST_COLLECTION}\", \"description\": \"Stats test\", \"tags\": [], \"collection_schema\": {\"temp\": \"float\", \"room\": \"text\"}}")
if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
    COLLECTION_ID=$(curl -s "${API_BASE}/projects/${PROJECT_ID}/collections" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        | jq -r --arg n "$TEST_COLLECTION" '.items[] | select(.collection_name==$n) | .collection_id // ""' \
        2>/dev/null || echo "")
    [ -n "$COLLECTION_ID" ] && [ "$COLLECTION_ID" != "null" ] \
        && pass "Collection created: $COLLECTION_ID" \
        || { fail "Collection created but could not resolve ID"; exit 1; }
else
    fail "Collection creation failed (HTTP $COLL_HTTP): $(cat "$_RESP_FILE")"
    exit 1
fi

_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"key_type": "read"}' >/dev/null
READ_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

_api POST "${API_BASE}/projects/${PROJECT_ID}/keys" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
    -d '{"key_type": "write"}' >/dev/null
WRITE_KEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || echo "")

[ -n "$READ_KEY" ] && [ "$READ_KEY" != "null" ] \
    && pass "API keys created" \
    || { fail "Failed to create API keys"; exit 1; }

STATS_URL="${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/statistics"

# ---------------------------------------------------------------------------
header "Data Ingestion (5 records with known temp values)"
# ---------------------------------------------------------------------------
# All records share the same key so stats aggregate within one partition bucket.
# The table PRIMARY KEY is ((day, key), timestamp) — records in the same
# partition overwrite each other when timestamps collide. sleep 1 between each
# POST guarantees distinct second-precision timestamps.
# Temperatures: 10, 20, 30, 40, 50  →  avg=30, min=10, max=50, sum=150, count=5
SENSOR_KEY="${RUN_ID}-sensor"
for temp in 10 20 30 40 50; do
    _api POST "${API_BASE}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/store_data" \
        -H "X-API-Key: ${WRITE_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"${SENSOR_KEY}\", \"temp\": ${temp}, \"room\": \"lab-01\"}" >/dev/null
    sleep 1
done
info "Ingested 5 records (temp: 10,20,30,40,50) with key=$SENSOR_KEY — waiting for consumer ..."
sleep 8

# ---------------------------------------------------------------------------
header "TEST_01: avg statistic"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    ROWS=$(jq 'length' "$_RESP_FILE" 2>/dev/null || echo "0")
    AVG=$(jq -r '.[0].avg_temp // "null"' "$_RESP_FILE" 2>/dev/null || echo "null")
    if [ "$ROWS" -ge 1 ] && [ "$AVG" != "null" ]; then
        pass "TEST_01a: avg returns $ROWS bucket(s), avg_temp=$AVG"
    else
        fail "TEST_01a: avg response shape wrong (rows=$ROWS, avg_temp=$AVG): $(cat "$_RESP_FILE")"
    fi
    # avg of 10+20+30+40+50 = 30.0
    AVG_INT=$(echo "$AVG" | jq -r 'floor | tostring' 2>/dev/null || echo "0")
    if [ "${AVG_INT:-0}" = "30" ]; then
        pass "TEST_01b: avg_temp correct (30.0)"
    else
        fail "TEST_01b: avg_temp expected ~30.0, got $AVG"
    fi
else
    fail "TEST_01: avg request failed (HTTP $HTTP): $(cat "$_RESP_FILE")"
fi

# ---------------------------------------------------------------------------
header "TEST_02: max statistic"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=max&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    MAX=$(jq -r '.[0].max_temp // "null"' "$_RESP_FILE" 2>/dev/null || echo "null")
    if [ "$MAX" = "50.0" ] || [ "$MAX" = "50" ]; then
        pass "TEST_02: max_temp=50 correct"
    else
        fail "TEST_02: max_temp expected 50, got $MAX: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_02: max request failed (HTTP $HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_03: min statistic"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=min&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    MIN=$(jq -r '.[0].min_temp // "null"' "$_RESP_FILE" 2>/dev/null || echo "null")
    if [ "$MIN" = "10.0" ] || [ "$MIN" = "10" ]; then
        pass "TEST_03: min_temp=10 correct"
    else
        fail "TEST_03: min_temp expected 10, got $MIN: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_03: min request failed (HTTP $HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_04: sum statistic"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=sum&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    SUM=$(jq -r '.[0].sum_temp // "null"' "$_RESP_FILE" 2>/dev/null || echo "null")
    SUM_INT=$(echo "$SUM" | jq -r 'floor | tostring' 2>/dev/null || echo "0")
    if [ "${SUM_INT:-0}" = "150" ]; then
        pass "TEST_04: sum_temp=150 correct"
    else
        fail "TEST_04: sum_temp expected 150, got $SUM: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_04: sum request failed (HTTP $HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_05: count statistic"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=count&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    COUNT=$(jq -r '.[0].count_temp // "null"' "$_RESP_FILE" 2>/dev/null || echo "null")
    if [ "${COUNT:-0}" = "5" ]; then
        pass "TEST_05: count_temp=5 correct"
    else
        fail "TEST_05: count_temp expected 5, got $COUNT: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_05: count request failed (HTTP $HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_06: Percentile stats (p50, p90, p95, p99)"
# ---------------------------------------------------------------------------
for pstat in p50 p90 p95 p99; do
    HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=${pstat}&interval=every_1_days" \
        -H "X-API-Key: ${READ_KEY}")
    if [ "$HTTP" = "200" ]; then
        ROWS=$(jq 'length' "$_RESP_FILE" 2>/dev/null || echo "0")
        VAL=$(jq -r ".[0].${pstat}_temp // \"null\"" "$_RESP_FILE" 2>/dev/null || echo "null")
        if [ "$ROWS" -ge 1 ] && [ "$VAL" != "null" ]; then
            pass "TEST_06_${pstat}: ${pstat}_temp present and non-null (value=$VAL)"
        else
            fail "TEST_06_${pstat}: ${pstat}_temp missing or null: $(cat "$_RESP_FILE")"
        fi
    else
        fail "TEST_06_${pstat}: request failed (HTTP $HTTP): $(cat "$_RESP_FILE")"
    fi
done

# ---------------------------------------------------------------------------
header "TEST_07: distinct statistic"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=room&stat=distinct" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    STAT_FIELD=$(jq -r '.stat // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    ATTR_FIELD=$(jq -r '.attribute // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    KEY_STATS=$(jq 'has("key_statistics")' "$_RESP_FILE" 2>/dev/null || echo "false")
    TOTAL_KEYS=$(jq -r '.total_keys // "null"' "$_RESP_FILE" 2>/dev/null || echo "null")
    BUCKETS=$(jq -r '.interval_buckets' "$_RESP_FILE" 2>/dev/null || echo "null")
    if [ "$STAT_FIELD" = "distinct" ] && [ "$ATTR_FIELD" = "room" ] && [ "$KEY_STATS" = "true" ]; then
        pass "TEST_07a: distinct response has correct shape (stat, attribute, key_statistics)"
    else
        fail "TEST_07a: distinct shape wrong: $(cat "$_RESP_FILE")"
    fi
    if [ "${TOTAL_KEYS:-0}" -ge 1 ]; then
        pass "TEST_07b: total_keys=$TOTAL_KEYS (≥1 key found)"
    else
        fail "TEST_07b: total_keys=$TOTAL_KEYS (expected ≥1)"
    fi
    if [ "$BUCKETS" = "null" ]; then
        pass "TEST_07c: interval_buckets=null when no interval provided"
    else
        fail "TEST_07c: interval_buckets should be null without interval, got: $BUCKETS"
    fi
else
    fail "TEST_07: distinct request failed (HTTP $HTTP): $(cat "$_RESP_FILE")"
fi

# ---------------------------------------------------------------------------
header "TEST_08: distinct with interval → interval_buckets populated"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=room&stat=distinct&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    BUCKETS_LEN=$(jq '.interval_buckets | if . == null then 0 else length end' "$_RESP_FILE" 2>/dev/null || echo "0")
    HAS_BUCKET_KEY=$(jq -r '.interval_buckets[0] | has("distinct_room")' "$_RESP_FILE" 2>/dev/null || echo "false")
    if [ "${BUCKETS_LEN:-0}" -ge 1 ]; then
        pass "TEST_08a: interval_buckets has $BUCKETS_LEN entry(ies)"
    else
        fail "TEST_08a: interval_buckets empty or null when interval=every_1_days: $(cat "$_RESP_FILE")"
    fi
    if [ "$HAS_BUCKET_KEY" = "true" ]; then
        pass "TEST_08b: interval_buckets[0] has distinct_room field"
    else
        fail "TEST_08b: interval_buckets[0] missing distinct_room: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_08: distinct+interval request failed (HTTP $HTTP): $(cat "$_RESP_FILE")"
fi

# ---------------------------------------------------------------------------
header "TEST_09: Interval bucketing (interval_start in results)"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    HAS_INTERVAL_START=$(jq '.[0] | has("interval_start")' "$_RESP_FILE" 2>/dev/null || echo "false")
    if [ "$HAS_INTERVAL_START" = "true" ]; then
        INTERVAL_START=$(jq -r '.[0].interval_start' "$_RESP_FILE" 2>/dev/null || echo "")
        pass "TEST_09: interval_start present in results ($INTERVAL_START)"
    else
        fail "TEST_09: interval_start missing from results: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_09: request failed (HTTP $HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_10: group_by parameter"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days&group_by=room" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    HAS_ROOM=$(jq '.[0] | has("room")' "$_RESP_FILE" 2>/dev/null || echo "false")
    if [ "$HAS_ROOM" = "true" ]; then
        ROOM_VAL=$(jq -r '.[0].room' "$_RESP_FILE" 2>/dev/null || echo "")
        pass "TEST_10: group_by=room produces 'room' field in results (value: $ROOM_VAL)"
    else
        fail "TEST_10: group_by=room but 'room' field missing: $(cat "$_RESP_FILE")"
    fi
else
    fail "TEST_10: group_by request failed (HTTP $HTTP): $(cat "$_RESP_FILE")"
fi

# ---------------------------------------------------------------------------
header "TEST_11: Time range filtering (start_time / end_time)"
# ---------------------------------------------------------------------------
START="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')"
END="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_hours&start_time=${START}&end_time=${END}" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    pass "TEST_11a: start_time+end_time with avg returns 200"
else
    fail "TEST_11a: time range request failed (HTTP $HTTP): $(cat "$_RESP_FILE")"
fi

# start_time only
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=count&interval=every_1_hours&start_time=${START}" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    pass "TEST_11b: start_time only returns 200"
else
    fail "TEST_11b: start_time-only request failed (HTTP $HTTP)"
fi

# end_time only
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=count&interval=every_1_hours&end_time=${END}" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    pass "TEST_11c: end_time only returns 200"
else
    fail "TEST_11c: end_time-only request failed (HTTP $HTTP)"
fi

# ---------------------------------------------------------------------------
header "TEST_12: Invalid interval format → 422"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_bad_format" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "422" ]; then
    pass "TEST_12a: 'every_bad_format' correctly rejected (422)"
else
    fail "TEST_12a: 'every_bad_format' returned HTTP $HTTP (expected 422)"
fi

HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_2_centuries" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "422" ]; then
    DETAIL=$(jq -r '.detail // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    pass "TEST_12b: 'every_2_centuries' correctly rejected (422)"
    info "  Detail: $DETAIL"
else
    fail "TEST_12b: 'every_2_centuries' returned HTTP $HTTP (expected 422)"
fi

# ---------------------------------------------------------------------------
header "TEST_13: Non-existent attribute → 422"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=nonexistent_field&stat=avg&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "422" ]; then
    DETAIL=$(jq -r '.detail // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    pass "TEST_13: Non-existent attribute rejected (422)"
    info "  Detail: $DETAIL"
else
    fail "TEST_13: Non-existent attribute returned HTTP $HTTP (expected 422): $(cat "$_RESP_FILE")"
fi

# ---------------------------------------------------------------------------
header "TEST_14: Non-existent group_by field → 422"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days&group_by=bad_field" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "422" ]; then
    pass "TEST_14: Non-existent group_by rejected (422)"
else
    fail "TEST_14: Non-existent group_by returned HTTP $HTTP (expected 422)"
fi

# ---------------------------------------------------------------------------
header "TEST_15: distinct without attribute → 422"
# ---------------------------------------------------------------------------
HTTP=$(_api GET "${STATS_URL}?stat=distinct" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "422" ]; then
    DETAIL=$(jq -r '.detail // ""' "$_RESP_FILE" 2>/dev/null || echo "")
    pass "TEST_15: distinct without attribute rejected (422)"
    info "  Detail: $DETAIL"
else
    fail "TEST_15: distinct without attribute returned HTTP $HTTP (expected 422)"
fi

# ---------------------------------------------------------------------------
header "TEST_16: Auth enforcement"
# ---------------------------------------------------------------------------
# Unauthenticated
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days")
if [ "$HTTP" = "401" ] || [ "$HTTP" = "403" ]; then
    pass "TEST_16a: Unauthenticated request rejected ($HTTP)"
else
    fail "TEST_16a: Unauthenticated request accepted (HTTP $HTTP)"
fi

# Read key accepted
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days" \
    -H "X-API-Key: ${READ_KEY}")
if [ "$HTTP" = "200" ]; then
    pass "TEST_16b: Read key accepted (200)"
else
    fail "TEST_16b: Read key rejected (HTTP $HTTP)"
fi

# Bearer token accepted
HTTP=$(_api GET "${STATS_URL}?attribute=temp&stat=avg&interval=every_1_days" \
    -H "Authorization: Bearer ${API_TOKEN}")
if [ "$HTTP" = "200" ]; then
    pass "TEST_16c: Bearer token accepted (200)"
else
    fail "TEST_16c: Bearer token rejected (HTTP $HTTP)"
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
    printf '\033[1;31mSTATISTICS TEST FAILED\033[0m\n'
    exit 1
else
    printf '\033[1;32mSTATISTICS TEST PASSED\033[0m\n'
    exit 0
fi
