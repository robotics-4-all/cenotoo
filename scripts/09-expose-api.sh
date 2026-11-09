#!/usr/bin/env bash
# =============================================================================
# scripts/09-expose-api.sh — Idempotent TLS apply entrypoint (Task 9, plan
# tls-ingress-exposure)
# -----------------------------------------------------------------------------
# Renders 00-traefik, 07-api, 08-dashboard, 09-mqtt into .rendered/k8s/ and
# applies in order: HelmChartConfig, ClusterIssuer, TLSStore, Certificate,
# ingresses, IngressRouteTCP. Waits up to 300s for Certificate Ready unless
# --no-wait, then runs the Task 13 legacy-cleanup block (never before Ready).
#
# Usage:
#   scripts/09-expose-api.sh [--non-interactive] [--no-wait]
#                           [--force-legacy-nodeport] [--help]
#   No flags            -> interactive: prompt for domain/contact, persist
#                          deploy/k8s/cenotoo.env (mode 0644), then apply.
#   --non-interactive   -> require existing cenotoo.env; fail otherwise.
#   --no-wait           -> skip the Certificate Ready wait (and the
#                          post-Ready cleanup, which never runs before Ready).
#   --force-legacy-nodeport -> EMERGENCY ROLLBACK ONLY: restore NodePort
#                          services from git, skip the TLS apply, print an
#                          explicit plaintext warning, exit 0.
#
# Legacy NodePort/plaintext mode is REMOVED (ruling R7, TLS-only
# constraint). Any explicit request for it without the rollback flag is
# refused with exit 2. The rollback flag is never presented as supported.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/domain.sh"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

MANIFEST_DIR="$PROJECT_DIR/deploy/k8s"
RENDERED_DIR="$PROJECT_DIR/.rendered/k8s"
CERT_READY_TIMEOUT=300

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Idempotent TLS apply entrypoint for Cenotoo public endpoints.

Options:
  --non-interactive        Require existing $MANIFEST_DIR/cenotoo.env;
                           fail if it is missing. No prompts.
  --no-wait                Skip the Certificate Ready wait (and the
                           post-Ready legacy cleanup).
  --force-legacy-nodeport  EMERGENCY ROLLBACK ONLY. Restores NodePort
                           services from git, skips the TLS apply, prints
                           a plaintext warning, exits 0. Not a supported
                           mode — traffic is unencrypted.
  --help, -h               Show this help.

With no options, prompts for domain/contact, persists cenotoo.env,
renders templates, applies in order, waits for Certificate Ready, runs
legacy cleanup, and prints the endpoint summary.
EOF
}

# ---- Legacy NodePort refusal (default) --------------------------------------
# Plaintext NodePort mode was removed (ruling R7). Exit 2 with a security
# warning — never silently downgrade to HTTP.
refuse_legacy_nodeport() {
    echo "" >&2
    warn "Legacy NodePort/plaintext mode is REMOVED (TLS-only constraint)." >&2
    warn "Exposing the API over plaintext HTTP leaks credentials and tokens." >&2
    warn "Run without rollback flags to apply TLS ingress instead." >&2
    warn "Emergency rollback only: $0 --force-legacy-nodeport" >&2
    echo "" >&2
    exit 2
}

# ---- Emergency rollback (flag only; never presented as supported) -----------
# Restores NodePort services from git, skips the TLS apply, warns loudly.
rollback_legacy_nodeport() {
    echo "" >&2
    warn "EMERGENCY ROLLBACK: restoring plaintext NodePort services." >&2
    warn "TRAFFIC WILL BE UNENCRYPTED on ports 30080/30081/30683." >&2
    warn "This is NOT a supported mode. Re-run without this flag to restore TLS." >&2
    echo "" >&2
    git -C "$PROJECT_DIR" checkout -- \
        deploy/k8s/07-api/service.yaml \
        deploy/k8s/08-dashboard/service.yaml \
        deploy/k8s/10-coap/coap-bridge-service.yaml
    ok "Restored NodePort service manifests from git."
    require_cmd kubectl "Install kubectl, then re-run this script."
    kubectl apply -f "$MANIFEST_DIR/07-api/service.yaml" -n "${CENOTOO_NAMESPACE:-cenotoo}"
    kubectl apply -f "$MANIFEST_DIR/08-dashboard/service.yaml" -n "${CENOTOO_NAMESPACE:-cenotoo}"
    kubectl apply -f "$MANIFEST_DIR/10-coap/coap-bridge-service.yaml" -n "${CENOTOO_NAMESPACE:-cenotoo}"
    warn "Rollback complete: plaintext NodePorts 30080/30081/30683 restored. Traffic is UNENCRYPTED."
    exit 0
}

NON_INTERACTIVE=false
NO_WAIT=false
FORCE_LEGACY=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --no-wait)
            NO_WAIT=true
            shift
            ;;
        --force-legacy-nodeport)
            FORCE_LEGACY=true
            shift
            ;;
        --nodeport|--http-only|--no-tls|--plaintext|legacy)
            refuse_legacy_nodeport
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1. See --help."
            ;;
    esac
done

banner "Cenotoo Public TLS — Expose via Ingress"

# ---- Config: interactive persists, non-interactive requires -----------------
if [ "$FORCE_LEGACY" = "true" ]; then
    : "${CENOTOO_NAMESPACE:=cenotoo}"
    export CENOTOO_NAMESPACE
    rollback_legacy_nodeport
fi

if [ "$NON_INTERACTIVE" = "true" ]; then
    if [ ! -f "$CENOTOO_ENV_FILE" ]; then
        fail "No config at $CENOTOO_ENV_FILE. Run scripts/set-domain.sh --domain <base-domain> --email <ops@example.com> first (--non-interactive never prompts)."
    fi
    cenotoo_load_config
    cenotoo_derive_hosts
else
    cenotoo_load_config
    prompt CENOTOO_BASE_DOMAIN "Base domain" "${CENOTOO_BASE_DOMAIN:-}"
    prompt CENOTOO_TLS_EMAIL "Contact address for ACME registration" "${CENOTOO_TLS_EMAIL:-}"
    export CENOTOO_BASE_DOMAIN CENOTOO_TLS_EMAIL
    # Validate via the shared lib (no duplicated regexes); fails before write.
    cenotoo_derive_hosts
    {
        printf 'CENOTOO_BASE_DOMAIN=%s\n' "$CENOTOO_BASE_DOMAIN"
        printf 'CENOTOO_TLS_EMAIL=%s\n' "$CENOTOO_TLS_EMAIL"
        printf 'CENOTOO_NAMESPACE=%s\n' "${CENOTOO_NAMESPACE:-cenotoo}"
        printf 'CENOTOO_ACME_SERVER=%s\n' "${CENOTOO_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
        printf 'CENOTOO_COAP_ENABLED=%s\n' "${CENOTOO_COAP_ENABLED:-false}"
    } > "$CENOTOO_ENV_FILE"
    chmod 0644 "$CENOTOO_ENV_FILE"
    ok "Wrote $CENOTOO_ENV_FILE (mode 0644)."
fi

NAMESPACE="$CENOTOO_NAMESPACE"
info "Base domain: $CENOTOO_BASE_DOMAIN"
info "Namespace: $NAMESPACE"

require_cmd kubectl "Install kubectl, then re-run this script."

# ---- Render all four trees ---------------------------------------------------
step 1 5 "Render templates to .rendered/k8s"
for _d in 00-traefik 07-api 08-dashboard 09-mqtt; do
    cenotoo_render_tree "$MANIFEST_DIR/$_d" "$RENDERED_DIR/$_d"
done

# ---- CoAP SAN placeholder (Task 5 header contract) ---------------------------
# The marker line is NOT valid dnsNames content and CENOTOO_COAP_ENABLED is
# deliberately NOT in the render allow-list, so branch here with sed: expand
# to the derived coap host entry when enabled, delete the line otherwise.
# The marker must never reach the rendered tree.
RENDERED_CERT="$RENDERED_DIR/00-traefik/certificate.yaml"
if [ ! -f "$RENDERED_CERT" ]; then
    fail "Rendered certificate not found: $RENDERED_CERT."
fi
if [ "${CENOTOO_COAP_ENABLED:-false}" = "true" ]; then
    sed -i "s|^    # __CENOTOO_COAP_SAN__$|    - ${CENOTOO_COAP_HOST}|" "$RENDERED_CERT"
    info "CoAP enabled: added ${CENOTOO_COAP_HOST} to certificate SAN list."
else
    sed -i "/^    # __CENOTOO_COAP_SAN__$/d" "$RENDERED_CERT"
    info "CoAP disabled: coap SAN omitted (internal-only)."
fi
if grep -q "^    # __CENOTOO_COAP_SAN__$" "$RENDERED_CERT"; then
    fail "CoAP placeholder leaked into $RENDERED_CERT — render contract violated."
fi
ok "Certificate SAN list finalized (no placeholder remains)."

# ---- Apply in order ----------------------------------------------------------
step 2 5 "Apply manifests in order"
info "Apply: HelmChartConfig (kube-system, Traefik entrypoints) ..."
kubectl apply -f "$MANIFEST_DIR/00-traefik/helmchartconfig.yaml"
info "Apply: ClusterIssuer cenotoo-letsencrypt ..."
kubectl apply -f "$RENDERED_DIR/00-traefik/clusterissuer.yaml"
info "Apply: TLSStore/default in $NAMESPACE ..."
kubectl apply -f "$RENDERED_DIR/00-traefik/tlsstore.yaml" -n "$NAMESPACE"
info "Apply: Certificate cenotoo-public-tls ..."
kubectl apply -f "$RENDERED_CERT" -n "$NAMESPACE"
info "Apply: API + dashboard ingresses ..."
kubectl apply -f "$RENDERED_DIR/07-api/ingress.yaml" -n "$NAMESPACE"
kubectl apply -f "$RENDERED_DIR/08-dashboard/ingress.yaml" -n "$NAMESPACE"
info "Apply: MQTT IngressRouteTCP ..."
kubectl apply -f "$RENDERED_DIR/09-mqtt/mqtt-ingressroutetcp.yaml" -n "$NAMESPACE"
ok "All manifests applied."

# ---- Wait for Certificate Ready ----------------------------------------------
CERT_READY="Unknown"
if [ "$NO_WAIT" = "true" ]; then
    warn "--no-wait: skipping Certificate Ready check (legacy cleanup also skipped)."
else
    step 3 5 "Wait for Certificate Ready (up to ${CERT_READY_TIMEOUT}s)"
    ELAPSED=0
    while [ "$ELAPSED" -lt "$CERT_READY_TIMEOUT" ]; do
        CERT_READY="$(kubectl get certificate cenotoo-public-tls -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")"
        if [ "$CERT_READY" = "True" ]; then
            ok "Certificate cenotoo-public-tls is Ready."
            break
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    if [ "$CERT_READY" != "True" ]; then
        warn "Certificate not Ready after ${CERT_READY_TIMEOUT}s (status: ${CERT_READY:-Unknown})."
        warn "ACME hint: HTTP-01 needs DNS A records pointing at this node AND port 80 reachable; staging first: CENOTOO_ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory."
        dimtext "Check: kubectl -n $NAMESPACE describe certificate cenotoo-public-tls"
        dimtext "Check: kubectl -n $NAMESPACE describe order,challenges"
        fail "Certificate issuance timed out — legacy cleanup NOT run (re-run after DNS/port 80 validate)."
    fi
fi

# ---- Task 13 cleanup: ONLY after the Ready check passes, never before --------
if [ "$NO_WAIT" = "true" ]; then
    warn "Post-Ready legacy cleanup skipped (--no-wait). Re-run without --no-wait once the certificate is Ready."
else
    step 4 5 "Legacy TLS artefact cleanup (Task 13)"
    kubectl delete certificate cenotoo-api-tls --ignore-not-found -n "$NAMESPACE"
    kubectl delete certificate cenotoo-dashboard-tls --ignore-not-found -n "$NAMESPACE"
    kubectl delete secret cenotoo-api-tls --ignore-not-found -n "$NAMESPACE"
    kubectl delete secret cenotoo-dashboard-tls --ignore-not-found -n "$NAMESPACE"
    # Strip leftover competing-owner annotations (ruling R5); tolerate absence.
    kubectl annotate ingress cenotoo-api cert-manager.io/cluster-issuer- -n "$NAMESPACE" 2>/dev/null || true
    kubectl annotate ingress cenotoo-dashboard cert-manager.io/cluster-issuer- -n "$NAMESPACE" 2>/dev/null || true
    ok "Legacy per-host certificates/secrets removed; sole owner is Certificate cenotoo-public-tls."
fi

# ---- Endpoint summary ---------------------------------------------------------
step 5 5 "Done"
box \
    "API:   https://${CENOTOO_API_HOST}" \
    "Docs:  https://${CENOTOO_API_HOST}/docs" \
    "Dash:  https://${CENOTOO_DASHBOARD_HOST}" \
    "MQTT:  mqtts://${CENOTOO_MQTT_HOST}:8883 (broker plaintext on 1883 in-cluster)"
cenotoo_dns_report
ok "Public TLS exposure applied (idempotent — safe to re-run)."
