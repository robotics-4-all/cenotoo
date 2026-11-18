#!/usr/bin/env bash
# =============================================================================
# 26-test-remote-tls.sh — Remote (laptop-side) TLS ingress verification
#
# Verifies the public HTTPS / MQTTS ingress exactly as an external client sees
# it, from outside the cluster:
#   1. TCP reachability of 443 and 8883
#   2. Server certificate chain + SANs (IP:<node-ip>, api/dashboard/mqtt DNS)
#   3. HTTPS endpoints (API docs, dashboard, /health) and the permanent
#      HTTP→HTTPS redirect (Traefik answers 308 or 301 depending on config)
#   4. MQTT-over-TLS publish with a write key → REST get_data read-back
#   5. Optional: the full SDK e2e suite (e2e-sdk-tests/run-e2e.sh)
#
# No kubectl, no port-forward, no KUBECONFIG — this script owns no cluster
# resources beyond the ephemeral project it creates and deletes.
# Certificates are ALWAYS verified (--cacert / -CAfile / --cafile); this script
# never uses --insecure.
#
# Environment:
#   CENOTOO_BASE_URL        API base URL           (default: https://api.cenotoo.local)
#   CENOTOO_NODE_IP         Ingress node IP. When set, every request is pinned
#                           with curl --resolve, and TLS probes / MQTT connect
#                           by IP, so the public hostnames need no local DNS.
#   CENOTOO_CA_BUNDLE       PEM CA bundle for the ingress certificate
#                           (self-signed mode). Unset → system trust store.
#   CENOTOO_USERNAME        API user               (default: discovered from
#                           .secrets/credentials.txt, else "nostradamus")
#   CENOTOO_ADMIN_PASSWORD  API password           (falls back to CENOTOO_PASSWORD,
#                           then to .secrets/credentials.txt)
#   CENOTOO_CREDENTIALS_FILE Override the credentials file path
#                           (default: <repo>/.secrets/credentials.txt)
#   CENOTOO_DASHBOARD_HOST  Dashboard host         (default: dashboard.<base-domain>)
#   CENOTOO_MQTT_HOST       MQTT host              (default: mqtt.<base-domain>)
#   CENOTOO_ORG_NAME        Organization segment   (default: read from the API)
#   REMOTE_E2E_TIMEOUT_S    Data read-back timeout (default: 90)
#
# Prerequisites: curl, openssl, jq, mosquitto_pub.
#
# Usage:
#   CENOTOO_NODE_IP=203.0.113.10 \
#   CENOTOO_CA_BUNDLE=./cenotoo-local-ca.crt \
#   CENOTOO_ADMIN_PASSWORD='<pass>' \
#     ./scripts/26-test-remote-tls.sh [--with-e2e]
#
#   --with-e2e   also run e2e-sdk-tests/run-e2e.sh for full API feature
#                coverage over the same HTTPS ingress.
# =============================================================================
set -euo pipefail

# Integrity guard: if a "# ---" separator line lost its leading "#" (stale or
# hand-edited copy), bash executes it as a command and aborts mid-run. Fail
# fast with an actionable message instead of a confusing "command not found".
if grep -qE '^[[:space:]]*-{3,}[[:space:]]*$' "$0" 2>/dev/null; then
    printf 'ERROR: %s is a corrupted/stale copy (separator lines lost their "#").\n' "$0" >&2
    printf 'Fix: git checkout -- %s   (or: git pull)\n' "$0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="${CENOTOO_BASE_URL:-https://api.cenotoo.local}"
BASE_URL="${BASE_URL%/}"
NODE_IP="${CENOTOO_NODE_IP:-}"
CA_BUNDLE="${CENOTOO_CA_BUNDLE:-}"
ORG_NAME_OVERRIDE="${CENOTOO_ORG_NAME:-}"
TIMEOUT_S="${REMOTE_E2E_TIMEOUT_S:-90}"

# install.sh records the seeded admin account here (chmod 600). Discover it so a
# deployment whose username is NOT the default (nostradamus) still works: the
# credentials file wins over the built-in default, env export wins over both.
CRED_FILE="${CENOTOO_CREDENTIALS_FILE:-$PROJECT_DIR/.secrets/credentials.txt}"
cred_field() {
    local key="$1"
    [ -r "$CRED_FILE" ] || return 1
    grep -E "^(${key})=" "$CRED_FILE" 2>/dev/null | head -n1 | cut -d= -f2- \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}
USERNAME="${CENOTOO_USERNAME:-$(cred_field 'ADMIN_USERNAME|CENOTOO_ADMIN_USERNAME' || true)}"
USERNAME="${USERNAME:-nostradamus}"
PASSWORD="${CENOTOO_ADMIN_PASSWORD:-${CENOTOO_PASSWORD:-$(cred_field 'ADMIN_PASSWORD|CENOTOO_ADMIN_PASSWORD' || true)}}"

WITH_E2E=false
if [ "${1:-}" = "--with-e2e" ]; then
    WITH_E2E=true
fi

# Derived endpoints — api.<base-domain> → dashboard.<base-domain>, mqtt.<base-domain>
API_HOST="${BASE_URL#*://}"
API_HOST="${API_HOST%%/*}"
API_HOST="${API_HOST%%:*}"
BASE_DOMAIN="${API_HOST#api.}"
DASHBOARD_HOST="${CENOTOO_DASHBOARD_HOST:-dashboard.${BASE_DOMAIN}}"
MQTT_HOST="${CENOTOO_MQTT_HOST:-mqtt.${BASE_DOMAIN}}"
API_V1="${BASE_URL}/api/v1"

passed=0
failed=0

pass()  { printf '\033[1;32m  PASS\033[0m  %s\n' "$*"; passed=$((passed + 1)); }
fail()  { printf '\033[1;31m  FAIL\033[0m  %s\n' "$*"; failed=$((failed + 1)); }
info()  { printf '\033[1;34m  ....\033[0m  %s\n' "$*"; }
header(){ printf '\n\033[1;36m--- %s ---\033[0m\n' "$*"; }

# Every curl runs with an optional --cacert (never --insecure). -sS keeps
# transport errors visible without dumping headers/bodies.
CURL_BASE=(-sS -m 20)
if [ -n "$CA_BUNDLE" ]; then
    CURL_BASE+=(--cacert "$CA_BUNDLE")
fi

# Pin the public hostnames to the ingress node when it is known. Entries for
# hosts a given call does not use are ignored by curl.
RESOLVE_OPTS=()
if [ -n "$NODE_IP" ]; then
    RESOLVE_OPTS=(
        --resolve "${API_HOST}:443:${NODE_IP}"
        --resolve "${API_HOST}:80:${NODE_IP}"
        --resolve "${DASHBOARD_HOST}:443:${NODE_IP}"
    )
fi

# Guarded expansion keeps empty arrays safe on bash < 4.4 under set -u.
curl_tls() { curl "${CURL_BASE[@]}" ${RESOLVE_OPTS[@]+"${RESOLVE_OPTS[@]}"} "$@"; }

_RESP_FILE="$(mktemp)"
CERT_PEM="$(mktemp)"
PROJECT_ID=""
TOKEN=""

cleanup() {
    if [ -n "${PROJECT_ID:-}" ] && [ -n "${TOKEN:-}" ]; then
        info "Deleting ephemeral project ${PROJECT_ID} ..."
        curl_tls -o /dev/null -X DELETE \
            "${API_V1}/projects/${PROJECT_ID}" \
            -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true
    fi
    rm -f "$_RESP_FILE" "$CERT_PEM"
}
trap cleanup EXIT

# _api: run a request, print the HTTP status code, body → $_RESP_FILE.
_api() {
    local method="$1" url="$2"; shift 2
    local http
    http=$(curl_tls -o "$_RESP_FILE" -w '%{http_code}' -X "$method" "$@" "$url" 2>/dev/null) || http="000"
    echo "${http:-000}"
}

summary() {
    header "Summary"
    echo "remote TLS checks: ${passed} passed, ${failed} failed"
}

# ---------------------------------------------------------------------------
header "Preflight"
# ---------------------------------------------------------------------------
missing_cmds=()
for cmd in curl openssl jq mosquitto_pub; do
    if command -v "$cmd" &>/dev/null; then
        pass "Command available: $cmd"
    else
        fail "Command not found: $cmd"
        missing_cmds+=("$cmd")
    fi
done
if [ "${#missing_cmds[@]}" -gt 0 ]; then
    printf '\n\033[1;31mInstall missing tools first: %s\033[0m\n' "${missing_cmds[*]}"
    summary
    exit 1
fi

if [ -z "$PASSWORD" ]; then
    fail "CENOTOO_ADMIN_PASSWORD (or CENOTOO_PASSWORD) is not set"
    printf '\n\033[1;31mRun: CENOTOO_ADMIN_PASSWORD=<pass> %s\033[0m\n' "$0"
    summary
    exit 2
fi
pass "API password is set (${#PASSWORD} chars)"

if [ -n "$CA_BUNDLE" ]; then
    if [ ! -f "$CA_BUNDLE" ]; then
        fail "CENOTOO_CA_BUNDLE is not a file: $CA_BUNDLE"
        summary
        exit 2
    fi
    CA_BUNDLE="$(cd "$(dirname "$CA_BUNDLE")" && pwd)/$(basename "$CA_BUNDLE")"
    pass "CA bundle: $CA_BUNDLE"
else
    info "CENOTOO_CA_BUNDLE unset — verifying against the system trust store"
fi

info "API:       $BASE_URL  (host $API_HOST)"
info "Dashboard: https://${DASHBOARD_HOST}"
info "MQTT:      mqtts://${MQTT_HOST}:8883"
if [ -n "$NODE_IP" ]; then
    info "Ingress node: $NODE_IP (requests pinned with curl --resolve)"
else
    info "CENOTOO_NODE_IP unset — relying on public DNS"
fi

# ---------------------------------------------------------------------------
header "TCP Reachability"
# ---------------------------------------------------------------------------
TCP_API_HOST="${NODE_IP:-$API_HOST}"
TCP_MQTT_HOST="${NODE_IP:-$MQTT_HOST}"

tcp_open() {
    local host="$1" port="$2"
    if command -v timeout &>/dev/null; then
        timeout 5 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null
    else
        (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
    fi
}

if tcp_open "$TCP_API_HOST" 443; then
    pass "TCP 443 open on ${TCP_API_HOST}"
else
    fail "TCP 443 closed/unreachable on ${TCP_API_HOST}"
fi

if tcp_open "$TCP_MQTT_HOST" 8883; then
    pass "TCP 8883 open on ${TCP_MQTT_HOST}"
else
    fail "TCP 8883 closed/unreachable on ${TCP_MQTT_HOST}"
fi

# ---------------------------------------------------------------------------
header "Certificate Chain + SANs"
# ---------------------------------------------------------------------------
PROBE_HOST="${NODE_IP:-$API_HOST}"

if openssl s_client -connect "${PROBE_HOST}:443" -servername "$API_HOST" -showcerts \
        </dev/null 2>/dev/null | openssl x509 -outform PEM >"$CERT_PEM" 2>/dev/null \
        && [ -s "$CERT_PEM" ]; then
    pass "Fetched server certificate from ${PROBE_HOST}:443 (SNI ${API_HOST})"
else
    fail "Could not fetch a server certificate from ${PROBE_HOST}:443"
fi

if [ -s "$CERT_PEM" ]; then
    if [ -n "$CA_BUNDLE" ]; then
        verify_out="$(openssl verify -CAfile "$CA_BUNDLE" "$CERT_PEM" 2>&1 || true)"
    else
        verify_out="$(openssl verify "$CERT_PEM" 2>&1 || true)"
    fi
    if printf '%s' "$verify_out" | grep -q ": OK"; then
        pass "Certificate chain verifies against the configured CA bundle"
    else
        fail "Certificate chain does NOT verify: $(printf '%s' "$verify_out" | head -n1)"
    fi

    SAN_TEXT="$(openssl x509 -in "$CERT_PEM" -noout -ext subjectAltName 2>/dev/null || true)"
    if [ -z "$SAN_TEXT" ]; then
        # OpenSSL < 1.1.1 has no -ext; fall back to the full text dump.
        SAN_TEXT="$(openssl x509 -in "$CERT_PEM" -noout -text 2>/dev/null \
            | grep -A1 'Subject Alternative Name' || true)"
    fi
    info "SANs: $(printf '%s' "$SAN_TEXT" | tr '\n' ' ' | sed 's/  */ /g')"

    for host in "$API_HOST" "$DASHBOARD_HOST" "$MQTT_HOST"; do
        if printf '%s' "$SAN_TEXT" | grep -qF "DNS:${host}"; then
            pass "SAN contains DNS:${host}"
        else
            fail "SAN missing DNS:${host}"
        fi
    done

    if [ -n "$NODE_IP" ]; then
        if printf '%s' "$SAN_TEXT" | grep -qF "IP Address:${NODE_IP}"; then
            pass "SAN contains IP:${NODE_IP}"
        else
            fail "SAN missing IP:${NODE_IP} (clients reaching the node by IP will not verify)"
        fi
    else
        info "CENOTOO_NODE_IP unset — skipping the IP SAN assertion"
    fi
fi

# ---------------------------------------------------------------------------
header "HTTPS Endpoints"
# ---------------------------------------------------------------------------
HEALTH_HTTP=$(_api GET "${BASE_URL}/health")
if [ "$HEALTH_HTTP" = "200" ]; then
    pass "GET ${BASE_URL}/health → 200 over TLS"
else
    fail "GET ${BASE_URL}/health → HTTP ${HEALTH_HTTP}"
fi

DOCS_HTTP=$(_api GET "${BASE_URL}/docs")
if [ "$DOCS_HTTP" = "200" ]; then
    pass "GET ${BASE_URL}/docs → 200 (API docs)"
else
    fail "GET ${BASE_URL}/docs → HTTP ${DOCS_HTTP}"
fi

DASH_HTTP=$(_api GET "https://${DASHBOARD_HOST}/")
if [ "$DASH_HTTP" = "200" ]; then
    pass "GET https://${DASHBOARD_HOST}/ → 200 (dashboard)"
else
    fail "GET https://${DASHBOARD_HOST}/ → HTTP ${DASH_HTTP}"
fi

# Traefik emits 308 for the entrypoint-level redirect and 301 for the
# redirectScheme middleware fallback — both are permanent redirects to HTTPS.
REDIRECT="$(curl_tls -o /dev/null -w '%{http_code} %{redirect_url}' \
    "http://${API_HOST}/docs" 2>/dev/null)" || REDIRECT="000 "
REDIRECT_HTTP="${REDIRECT%% *}"
REDIRECT_URL="${REDIRECT#* }"
case "$REDIRECT_HTTP" in
    301|308)
        if [ "${REDIRECT_URL#https://}" != "$REDIRECT_URL" ]; then
            pass "http://${API_HOST}/docs → ${REDIRECT_HTTP} ${REDIRECT_URL} (permanent HTTPS redirect)"
        else
            fail "http://${API_HOST}/docs → ${REDIRECT_HTTP} to a non-HTTPS location: ${REDIRECT_URL}"
        fi
        ;;
    *)
        fail "http://${API_HOST}/docs → HTTP ${REDIRECT_HTTP} (expected a 301/308 permanent redirect)"
        ;;
esac

# ---------------------------------------------------------------------------
header "REST Provisioning (ephemeral project)"
# ---------------------------------------------------------------------------
RUN_ID="remotetls_$(date +%s)"
PROJECT_NAME="$RUN_ID"
COLLECTION_NAME="telemetry"
MARKER="${RUN_ID}_marker"

if [ -n "$ORG_NAME_OVERRIDE" ]; then
    ORG_NAME="$ORG_NAME_OVERRIDE"
else
    ORG_NAME=""
fi

AUTH_HTTP=$(_api POST "${API_V1}/token" \
    --data-urlencode "username=${USERNAME}" \
    --data-urlencode "password=${PASSWORD}")
if [ "$AUTH_HTTP" = "200" ]; then
    TOKEN=$(jq -r '.access_token // ""' "$_RESP_FILE" 2>/dev/null || true)
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        pass "OAuth2 token issued for ${USERNAME} (${#TOKEN} chars)"
    else
        fail "Token response (HTTP 200) carried no access_token"
        TOKEN=""
    fi
else
    fail "POST ${API_V1}/token → HTTP ${AUTH_HTTP} (check CENOTOO_USERNAME / password)"
fi

if [ -z "$TOKEN" ]; then
    summary
    exit 1
fi

AUTH_HEADER="Authorization: Bearer ${TOKEN}"

if [ -z "$ORG_NAME" ]; then
    ORG_HTTP=$(_api GET "${API_V1}/organization" -H "$AUTH_HEADER")
    if [ "$ORG_HTTP" != "200" ]; then
        # Older API builds only expose the name-scoped route.
        ORG_HTTP=$(_api GET "${API_V1}/organization/nostradamus" -H "$AUTH_HEADER")
    fi
    if [ "$ORG_HTTP" = "200" ]; then
        ORG_NAME=$(jq -r '.organization_name // .name // ""' "$_RESP_FILE" 2>/dev/null || true)
    fi
    if [ -n "$ORG_NAME" ] && [ "$ORG_NAME" != "null" ]; then
        pass "Organization segment: ${ORG_NAME}"
    else
        fail "Cannot resolve the organization name (set CENOTOO_ORG_NAME to override)"
    fi
else
    pass "Organization segment (from CENOTOO_ORG_NAME): ${ORG_NAME}"
fi

PROJ_HTTP=$(_api POST "${API_V1}/projects" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"${PROJECT_NAME}\", \"description\": \"remote TLS ingress verification\", \"tags\": [\"e2e\", \"tls\"]}")
if [ "$PROJ_HTTP" = "200" ] || [ "$PROJ_HTTP" = "201" ]; then
    PROJECT_ID=$(jq -r '.id.project_id? // .project_id? // ""' "$_RESP_FILE" 2>/dev/null || true)
    if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
        pass "Project created: ${PROJECT_NAME} (${PROJECT_ID})"
    else
        fail "Project created but no project_id in response"
        PROJECT_ID=""
    fi
else
    fail "Project creation failed (HTTP ${PROJ_HTTP}): $(head -c 200 "$_RESP_FILE")"
fi

COLLECTION_ID=""
if [ -n "$PROJECT_ID" ]; then
    COLL_SCHEMA='{"key": "SCHEMA_KEY", "timestamp": "2026-01-01T00:00:00Z", "temperature": 21.5, "humidity": 50.0}'
    COLL_HTTP=$(_api POST "${API_V1}/projects/${PROJECT_ID}/collections" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${COLLECTION_NAME}\", \"description\": \"remote TLS verification\", \"tags\": [\"e2e\"], \"collection_schema\": ${COLL_SCHEMA}}")
    COLL_BODY="$(cat "$_RESP_FILE")"
    if [ "$COLL_HTTP" = "200" ] || [ "$COLL_HTTP" = "201" ]; then
        pass "Collection created: ${COLLECTION_NAME}"
    else
        fail "Collection creation failed (HTTP ${COLL_HTTP}): $(head -c 200 "$_RESP_FILE")"
    fi

    # Resolve the ID from the list endpoint (the create body only carries a
    # message on some builds); fall back to the UUID embedded in that message.
    LIST_HTTP=$(_api GET "${API_V1}/projects/${PROJECT_ID}/collections" -H "$AUTH_HEADER")
    if [ "$LIST_HTTP" = "200" ]; then
        COLLECTION_ID=$(jq -r --arg n "$COLLECTION_NAME" \
            '[ (.items // .collections // [])[]
               | select(.collection_name == $n or .name == $n)
               | (.collection_id? // (.id? | strings)) ] | .[0] // ""' \
            "$_RESP_FILE" 2>/dev/null || true)
    fi
    if [ -z "$COLLECTION_ID" ]; then
        COLLECTION_ID=$(printf '%s' "$COLL_BODY" \
            | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
            | head -n1 || true)
    fi
    if [ -n "$COLLECTION_ID" ] && [ "$COLLECTION_ID" != "null" ]; then
        pass "Collection ID resolved: ${COLLECTION_ID}"
    else
        fail "Cannot resolve the collection ID for ${COLLECTION_NAME}"
        COLLECTION_ID=""
    fi
fi

WKEY=""
if [ -n "$PROJECT_ID" ]; then
    KEY_HTTP=$(_api POST "${API_V1}/projects/${PROJECT_ID}/keys" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d '{"key_type": "write"}')
    if [ "$KEY_HTTP" = "200" ] || [ "$KEY_HTTP" = "201" ]; then
        WKEY=$(jq -r '.api_key // ""' "$_RESP_FILE" 2>/dev/null || true)
    fi
    if [ -n "$WKEY" ] && [ "$WKEY" != "null" ]; then
        pass "Write API key issued (${#WKEY} chars)"
    else
        fail "Write API key creation failed (HTTP ${KEY_HTTP})"
        WKEY=""
    fi
fi

# ---------------------------------------------------------------------------
header "MQTT over TLS (mqtts://${MQTT_HOST}:8883)"
# ---------------------------------------------------------------------------
MQTT_CONNECT_HOST="${NODE_IP:-$MQTT_HOST}"
MQTT_TOPIC="${ORG_NAME}/${PROJECT_NAME}/${COLLECTION_NAME}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PAYLOAD="{\"key\": \"${MARKER}\", \"timestamp\": \"${TS}\", \"temperature\": 21.5, \"humidity\": 50.0}"

if [ -n "$PROJECT_ID" ] && [ -n "$WKEY" ] && [ -n "$ORG_NAME" ] && [ -n "$COLLECTION_ID" ]; then
    info "Publishing as project ${PROJECT_ID} to ${MQTT_TOPIC} via ${MQTT_CONNECT_HOST}:8883 ..."
    # -u = project UUID (identity), -P = write API key (secret). Never logged.
    if [ -n "$CA_BUNDLE" ]; then
        MQTT_OK=false
        if mosquitto_pub -h "$MQTT_CONNECT_HOST" -p 8883 --cafile "$CA_BUNDLE" \
            -u "$PROJECT_ID" -P "$WKEY" -t "$MQTT_TOPIC" -q 1 -m "$PAYLOAD"; then
            MQTT_OK=true
        fi
    else
        MQTT_OK=false
        if mosquitto_pub -h "$MQTT_CONNECT_HOST" -p 8883 \
            -u "$PROJECT_ID" -P "$WKEY" -t "$MQTT_TOPIC" -q 1 -m "$PAYLOAD"; then
            MQTT_OK=true
        fi
    fi
    if [ "$MQTT_OK" = "true" ]; then
        pass "MQTT publish over TLS accepted (QoS 1)"
    else
        fail "MQTT publish over TLS failed (check CA trust, key scope, ACL and topic names)"
    fi
else
    fail "MQTT publish not attempted — project, collection, write key or org name missing"
fi

# ---------------------------------------------------------------------------
header "REST Read-Back (MQTT → bridge → Kafka → Cassandra)"
# ---------------------------------------------------------------------------
FILTERS="[{\"property_name\": \"key\", \"operator\": \"eq\", \"property_value\": \"${MARKER}\"}]"
FOUND=false

if [ -n "$COLLECTION_ID" ]; then
    DEADLINE=$(( $(date +%s) + TIMEOUT_S ))
    info "Polling get_data for key=${MARKER} (timeout ${TIMEOUT_S}s) ..."
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        READ_HTTP=$(_api GET "${API_V1}/projects/${PROJECT_ID}/collections/${COLLECTION_ID}/get_data" \
            -H "$AUTH_HEADER" -G \
            --data-urlencode "filters=${FILTERS}" \
            --data-urlencode "limit=20")
        if [ "$READ_HTTP" = "200" ] && grep -qF "$MARKER" "$_RESP_FILE"; then
            FOUND=true
            break
        fi
        sleep 3
    done
fi

if [ "$FOUND" = "true" ]; then
    pass "REST get_data returned the published row (key=${MARKER})"
else
    fail "Published row did not appear via get_data within ${TIMEOUT_S}s"
    info "Hint: check the mqtt-bridge / cassandra-writer logs for schema mismatches"
fi

# ---------------------------------------------------------------------------
if [ "$WITH_E2E" = "true" ]; then
    header "SDK e2e Suite (full API feature coverage)"
    info "Running e2e-sdk-tests/run-e2e.sh against ${BASE_URL} ..."
    if CENOTOO_BASE_URL="$BASE_URL" \
        CENOTOO_USERNAME="$USERNAME" \
        CENOTOO_PASSWORD="$PASSWORD" \
        CENOTOO_CA_BUNDLE="$CA_BUNDLE" \
        "$PROJECT_DIR/e2e-sdk-tests/run-e2e.sh"; then
        pass "SDK e2e suite green over HTTPS"
    else
        fail "SDK e2e suite failed over HTTPS"
    fi
else
    info "Skipping the SDK e2e suite (pass --with-e2e for full API feature coverage)"
fi

# ---------------------------------------------------------------------------
summary
if [ "$failed" -gt 0 ]; then
    printf '\n\033[1;31mRemote TLS verification FAILED (%d check(s))\033[0m\n' "$failed"
    exit 1
fi
printf '\n\033[1;32mAll remote TLS checks passed.\033[0m\n'
