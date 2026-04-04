#!/usr/bin/env bash
# =============================================================================
# configure-secrets.sh — Generate Cenotoo K8s secrets from environment variables
#
# Usage:
#   export CENOTOO_ADMIN_PASSWORD=MySecurePass123
#   export CENOTOO_JWT_SECRET=$(openssl rand -hex 32)
#   ./scripts/configure-secrets.sh
#
# All variables are optional. Unset variables keep their defaults.
# Run BEFORE 07-deploy-cenotoo.sh (or re-run + kubectl apply to update).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS_DIR="$(cd "$SCRIPT_DIR/../deploy/k8s/01-secrets" && pwd)"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

b64() { printf '%s' "$1" | base64 -w0; }
rand() { openssl rand -hex 32; }

JWT_SECRET="${CENOTOO_JWT_SECRET:-}"
API_KEY_SECRET="${CENOTOO_API_KEY_SECRET:-}"
CASSANDRA_USERNAME="${CENOTOO_CASSANDRA_USERNAME:-cassandra}"
CASSANDRA_PASSWORD="${CENOTOO_CASSANDRA_PASSWORD:-}"

if [ -z "$JWT_SECRET" ]; then
    JWT_SECRET=$(rand)
    ok "CENOTOO_JWT_SECRET not set — generated random 256-bit secret"
fi
if [ -z "$API_KEY_SECRET" ]; then
    API_KEY_SECRET=$(rand)
    ok "CENOTOO_API_KEY_SECRET not set — generated random 256-bit secret"
fi
if [ -z "$CASSANDRA_PASSWORD" ]; then
    warn "CENOTOO_CASSANDRA_PASSWORD not set — using default 'cassandra'"
    warn "Set it with: export CENOTOO_CASSANDRA_PASSWORD=<your-password>"
    CASSANDRA_PASSWORD="cassandra"
fi

info "Generating API secrets ..."
cat > "$SECRETS_DIR/api-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cenotoo-api-secrets
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: cenotoo
type: Opaque
data:
  jwt-secret-key: $(b64 "$JWT_SECRET")
  api-key-secret: $(b64 "$API_KEY_SECRET")
EOF
ok "Generated $SECRETS_DIR/api-secrets.yaml"

info "Generating Cassandra superuser secret ..."
cat > "$SECRETS_DIR/cassandra-superuser.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cenotoo-cassandra-superuser
  labels:
    app.kubernetes.io/part-of: cenotoo
type: Opaque
data:
  username: $(b64 "$CASSANDRA_USERNAME")
  password: $(b64 "$CASSANDRA_PASSWORD")
EOF
ok "Generated $SECRETS_DIR/cassandra-superuser.yaml"

echo ""
ok "Secrets configured"
info "Apply with: kubectl apply -f $SECRETS_DIR/ -n $NAMESPACE"
info "Or run: ./scripts/07-deploy-cenotoo.sh"
