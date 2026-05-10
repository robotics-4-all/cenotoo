#!/usr/bin/env bash
# =============================================================================
# 24-deploy-postgres.sh — Deploy PostgreSQL metadata database on k3s
#
# Deploys the PostgreSQL StatefulSet that backs the Cenotoo metadata layer:
#   • cenotoo-postgres   (postgres:16-alpine, single replica)
#
# PostgreSQL serves as the authoritative store for all metadata:
#   organizations, projects, collections, API keys, users, devices,
#   device shadows, rules, revoked tokens, and Flink job records.
#
# The init.sql schema is mounted via ConfigMap (cenotoo-postgres-init)
# and applied automatically on first boot. For existing clusters, run
# init-postgres-schema.sh to apply schema changes idempotently.
#
# Prerequisites: k3s (01), cenotoo namespace (07)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
PG_STATEFULSET="cenotoo-postgres"
PG_POD="cenotoo-postgres-0"
PG_TIMEOUT="${PG_TIMEOUT:-120}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

TOTAL_STEPS=3

info()    { echo -e "  ${BLUE}▸${RESET} $*"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}[$1/${TOTAL_STEPS}]${RESET} $2\n"; }
dimtext() { echo -e "  ${DIM}$*${RESET}"; }

echo ""
echo -e "${CYAN}${BOLD}  ╔═══════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}  ║   Cenotoo PostgreSQL — Deploy to k3s         ║${RESET}"
echo -e "${CYAN}${BOLD}  ╚═══════════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Preflight ────────────────────────────────────────────────────────
step 1 "Preflight checks"

command -v kubectl &>/dev/null || fail "kubectl is not installed"
ok "kubectl found"

command -v k3s &>/dev/null || fail "k3s is not installed"
ok "k3s found"

kubectl get ns "$NAMESPACE" &>/dev/null \
    || fail "Namespace '$NAMESPACE' not found — run 07-deploy-cenotoo.sh first"
ok "Namespace '$NAMESPACE' exists"

[ -d "$MANIFEST_DIR/11-postgres" ] \
    || fail "Postgres manifests not found at $MANIFEST_DIR/11-postgres"
ok "Manifests: $MANIFEST_DIR/11-postgres"

# Check secret exists — warn if missing (deploy will fail at pod startup)
if kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" &>/dev/null; then
    ok "Secret 'cenotoo-postgres-credentials' exists"
else
    warn "Secret 'cenotoo-postgres-credentials' not found in namespace '$NAMESPACE'"
    warn "Run configure-secrets.sh and apply the generated secret, or the pod will not start"
    warn "  kubectl apply -f deploy/k8s/01-secrets/postgres-credentials.yaml -n $NAMESPACE"
fi

# Check init SQL ConfigMap (created from postgres/init.sql)
if kubectl get configmap cenotoo-postgres-init -n "$NAMESPACE" &>/dev/null; then
    ok "ConfigMap 'cenotoo-postgres-init' exists"
else
    info "ConfigMap 'cenotoo-postgres-init' not found — will be created from manifests"
fi

# ── Step 2: Apply manifests ──────────────────────────────────────────────────
step 2 "Apply PostgreSQL manifests"

info "Applying manifests from $MANIFEST_DIR/11-postgres/ ..."
kubectl apply -f "$MANIFEST_DIR/11-postgres/" -n "$NAMESPACE"
ok "Manifests applied"

# Restart existing StatefulSet pod to pick up any ConfigMap or Secret changes
if kubectl get statefulset "$PG_STATEFULSET" -n "$NAMESPACE" &>/dev/null; then
    EXISTING_READY=$(kubectl get statefulset "$PG_STATEFULSET" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${EXISTING_READY:-0}" -ge 1 ]; then
        info "Restarting $PG_STATEFULSET to pick up any config changes ..."
        kubectl rollout restart statefulset/"$PG_STATEFULSET" -n "$NAMESPACE" 2>/dev/null || true
    fi
fi

# ── Step 3: Wait for readiness ───────────────────────────────────────────────
step 3 "Wait for PostgreSQL pod to be ready"

info "Waiting for pod ${PG_POD} to be Ready (timeout: ${PG_TIMEOUT}s) ..."
ELAPSED=0
READY=0
while [ "$ELAPSED" -lt "$PG_TIMEOUT" ]; do
    PHASE=$(kubectl get pod "$PG_POD" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    COND=$(kubectl get pod "$PG_POD" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$PHASE" = "Running" ] && [ "$COND" = "True" ]; then
        READY=1
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    dimtext "  ${ELAPSED}s / ${PG_TIMEOUT}s — phase: ${PHASE:-Pending}"
done

if [ "$READY" -eq 1 ]; then
    ok "Pod ${PG_POD} is Running and Ready"
else
    warn "${PG_POD} not Ready after ${PG_TIMEOUT}s"
    warn "Check: kubectl logs -n $NAMESPACE $PG_POD"
    warn "Check: kubectl describe pod $PG_POD -n $NAMESPACE"
fi

# Verify pg_isready from inside the pod
if [ "$READY" -eq 1 ]; then
    PG_USER=$(kubectl get secret cenotoo-postgres-credentials -n "$NAMESPACE" \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "cenotoo")
    if kubectl exec -n "$NAMESPACE" "$PG_POD" -- pg_isready -U "$PG_USER" &>/dev/null; then
        ok "PostgreSQL is accepting connections (pg_isready)"
    else
        warn "pg_isready check failed — database may still be initializing"
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "<node-ip>")

echo -e "  ┌──────────────────────────────────────────────────────┐"
echo -e "  │  ${GREEN}${BOLD}PostgreSQL deployed successfully${RESET}                    │"
echo -e "  │                                                      │"
printf  "  │  %-52s │\n" "Pod:      ${PG_POD}"
printf  "  │  %-52s │\n" "Service:  cenotoo-postgres.${NAMESPACE}:5432"
printf  "  │  %-52s │\n" "Image:    postgres:16-alpine"
echo -e "  │                                                      │"
echo -e "  │  ${DIM}Schema is applied automatically on first boot via${RESET}   │"
echo -e "  │  ${DIM}the cenotoo-postgres-init ConfigMap.${RESET}                │"
echo -e "  │                                                      │"
echo -e "  │  ${DIM}For existing clusters, run:${RESET}                         │"
echo -e "  │  ${DIM}  ./scripts/init-postgres-schema.sh${RESET}                 │"
echo -e "  └──────────────────────────────────────────────────────┘"
echo ""
