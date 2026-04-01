#!/usr/bin/env bash
# =============================================================================
# 11-deploy-flink-jobs.sh — Deploy Flink SQL Gateway + Flink Jobs API
#
# Applies the Phase 1 Flink live-aggregations feature:
#   1. Rebuilds custom-flink-image (SQL Gateway sidecar) and cenotoo-api
#   2. Applies updated Flink manifests (sidecar + ClusterIP service)
#   3. Waits for SQL Gateway readiness
#   4. Migrates Cassandra schema (adds flink_jobs table — idempotent)
#   5. Redeploys cenotoo-api with FLINK_SQL_GATEWAY_URL
#
# Safe to re-run — all operations are idempotent.
#
# Prerequisites: 07-deploy-cenotoo.sh, 08-deploy-api.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
CASSANDRA_POD="${CASSANDRA_POD:-cenotoo-cassandra-0}"
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
CASSANDRA_PASS="${CASSANDRA_PASS:-cassandra}"
CENOTOO_API_DIR="${CENOTOO_API_DIR:-$(cd "$PROJECT_DIR/../cenotoo-api" 2>/dev/null && pwd || echo "")}"

FLINK_IMAGE="custom-flink-image:latest"
API_IMAGE="cenotoo-api:latest"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

BOLD='\033[1m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
DIM='\033[2m'
RESET='\033[0m'

info()  { printf "${BLUE}▸${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
fail()  { printf "${RED}✗${RESET}  %s\n" "$*"; exit 1; }
step()  { printf "\n${BOLD}[%s]${RESET} %s\n\n" "$1" "$2"; }

run_cql() {
    local stmt="$1"
    kubectl exec -n "$NAMESPACE" "$CASSANDRA_POD" -- \
        cqlsh -u "$CASSANDRA_USER" -p "$CASSANDRA_PASS" -e "$stmt" 2>&1
}

wait_for_pods_ready() {
    local label="$1" timeout="${2:-180}"
    info "Waiting for pods ($label) to be ready ..."
    kubectl wait pod -n "$NAMESPACE" -l "$label" \
        --for=condition=Ready \
        --timeout="${timeout}s" >/dev/null 2>&1 || \
        fail "Pods ($label) not ready within ${timeout}s"
}

wait_for_deployment() {
    local name="$1" timeout="${2:-120}"
    local elapsed=0
    info "Waiting for deployment/$name ..."
    while [ "$elapsed" -lt "$timeout" ]; do
        local ready
        ready=$(kubectl get deployment "$name" -n "$NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        [ "${ready:-0}" -ge 1 ] && return 0
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Deployment $name not ready within ${timeout}s"
}

# =============================================================================
echo ""
printf "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════╗${RESET}\n"
printf "${CYAN}${BOLD}  ║     Cenotoo — Deploy Flink Jobs (Phase 1)       ║${RESET}\n"
printf "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════╝${RESET}\n"
echo ""

# ── Step 1: Preflight ────────────────────────────────────────────────────────
step "1/5" "Preflight checks"

command -v docker >/dev/null 2>&1 || fail "Docker not found"
ok "Docker found"

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
ok "kubectl found"

command -v k3s >/dev/null 2>&1 || fail "k3s not found"
ok "k3s found"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || fail "Namespace '$NAMESPACE' not found — run 07-deploy-cenotoo.sh first"
ok "Namespace '$NAMESPACE' exists"

kubectl get crd flinkdeployments.flink.apache.org >/dev/null 2>&1 || fail "Flink operator CRD not found — run 05-install-flink-operator.sh first"
ok "Flink operator CRD found"

kubectl get pod "$CASSANDRA_POD" -n "$NAMESPACE" >/dev/null 2>&1 || fail "Cassandra pod $CASSANDRA_POD not found — run 07-deploy-cenotoo.sh first"
ok "Cassandra pod found"

if [ -z "$CENOTOO_API_DIR" ] || [ ! -d "$CENOTOO_API_DIR" ]; then
    fail "cenotoo-api source not found. Set CENOTOO_API_DIR or clone it next to this repo."
fi
ok "cenotoo-api source: $CENOTOO_API_DIR"

# ── Step 2: Build + import images ────────────────────────────────────────────
step "2/5" "Build and import Docker images"

REBUILD=false
for arg in "$@"; do [ "$arg" = "--rebuild" ] && REBUILD=true; done

build_and_import() {
    local image="$1" context="$2"
    if [ "$REBUILD" = "false" ] && docker image inspect "$image" >/dev/null 2>&1; then
        ok "$image found locally — skipping build (use --rebuild to force)"
    else
        info "Building $image ..."
        docker build --pull=false -t "$image" "$context" --quiet || \
            fail "Build failed. Ensure base images are present: docker pull <base-image>"
        ok "Built $image"
    fi
    info "Importing $image into k3s ..."
    docker save "$image" | k3s ctr images import - >/dev/null
    ok "Imported $image"
}

build_and_import "$FLINK_IMAGE" "$PROJECT_DIR/flink"
build_and_import "$API_IMAGE"   "$CENOTOO_API_DIR"

# ── Step 3: Apply Flink manifests ────────────────────────────────────────────
step "3/5" "Apply Flink manifests and wait for SQL Gateway"

info "Applying Flink manifests (deployment + SQL Gateway service) ..."
kubectl apply -f "$MANIFEST_DIR/04-flink/" -n "$NAMESPACE"
ok "Flink manifests applied"

info "Restarting Flink JobManager pod to pick up SQL Gateway sidecar ..."
kubectl delete pod -n "$NAMESPACE" \
    -l "app=cenotoo-flink,component=jobmanager" \
    --ignore-not-found >/dev/null
ok "JobManager pod deleted — operator will recreate it"

wait_for_pods_ready "app=cenotoo-flink,component=jobmanager" 300
ok "SQL Gateway sidecar is ready"

# ── Step 4: Cassandra schema migration ───────────────────────────────────────
step "4/5" "Migrate Cassandra schema (flink_jobs table)"

info "Applying flink_jobs table (IF NOT EXISTS) ..."
FLINK_JOBS_DDL="CREATE TABLE IF NOT EXISTS metadata.flink_jobs (id UUID PRIMARY KEY, collection_id UUID, project_id UUID, session_handle TEXT, operation_handle TEXT, job_type TEXT, config TEXT, sink_topic TEXT, status TEXT, created_at TIMESTAMP);"
run_cql "$FLINK_JOBS_DDL"
ok "metadata.flink_jobs table ready"

info "Verifying table ..."
TABLE_CHECK=$(run_cql "SELECT table_name FROM system_schema.tables WHERE keyspace_name='metadata' AND table_name='flink_jobs';")
if echo "$TABLE_CHECK" | grep -q "flink_jobs"; then
    ok "Verified: metadata.flink_jobs"
else
    fail "Table metadata.flink_jobs not found after migration"
fi

# ── Step 5: Redeploy API ─────────────────────────────────────────────────────
step "5/5" "Redeploy cenotoo-api"

info "Applying API deployment (includes FLINK_SQL_GATEWAY_URL) ..."
kubectl apply -f "$MANIFEST_DIR/07-api/" -n "$NAMESPACE"

info "Restarting API pods ..."
kubectl rollout restart deployment/cenotoo-api -n "$NAMESPACE"

wait_for_deployment "cenotoo-api" 120
ok "cenotoo-api is running"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")

printf "  ┌─────────────────────────────────────────────────────┐\n"
printf "  │  ${GREEN}${BOLD}Flink Jobs (Phase 1) deployed${RESET}                      │\n"
printf "  │                                                     │\n"
printf "  │  %-53s│\n" "SQL Gateway:  cenotoo-flink-sql-gateway:8083"
printf "  │                                                     │\n"
printf "  │  New endpoints:                                     │\n"
printf "  │  %-53s│\n" "POST /projects/{pid}/collections/{cid}/jobs"
printf "  │  %-53s│\n" "GET  /projects/{pid}/collections/{cid}/jobs"
printf "  │  %-53s│\n" "GET  /projects/{pid}/collections/{cid}/jobs/{jid}"
printf "  │  %-53s│\n" "DELETE /projects/{pid}/collections/{cid}/jobs/{jid}"
printf "  │  %-53s│\n" "GET  /projects/{pid}/jobs"
printf "  │                                                     │\n"
printf "  │  ${DIM}Docs: http://${NODE_IP}:30080/docs${RESET}                   │\n"
printf "  └─────────────────────────────────────────────────────┘\n"
echo ""
ok "Done"
