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
#                           [--force-legacy-nodeport]
#                           [--self-signed --ip <addr>] [--help]
#   No flags            -> interactive: prompt for domain/contact, persist
#                          deploy/k8s/cenotoo.env (mode 0644), then apply.
#   --non-interactive   -> require existing cenotoo.env; fail otherwise.
#   --no-wait           -> skip the Certificate Ready wait (and the
#                          post-Ready cleanup, which never runs before Ready).
#   --force-legacy-nodeport -> EMERGENCY ROLLBACK ONLY: restore NodePort
#                          services from git, skip the TLS apply, print an
#                          explicit plaintext warning, exit 0.
#   --self-signed --ip <addr> -> No public domain: mint a local CA +
#                          server cert with SAN IP:<addr> (plus
#                          api/dashboard/mqtt DNS for compat) via
#                          openssl into the shared secret
#                          cenotoo-public-tls; skip ALL ACME logic.
#                          Mutually exclusive with rollback flag.
#
# Self-signed example: 09-expose-api.sh --self-signed --ip 203.0.113.10
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
  --self-signed            Mint a local CA + server cert (no domain).
                            Requires --ip <addr>. Skips ClusterIssuer,
                            Certificate, Ready wait, legacy cleanup.
  --ip <addr>              Node public IP for the self-signed SAN
                            (e.g. 203.0.113.10). IPv4 validated;
                            IPv6 (colon-hex) accepted.
  --help, -h               Show this help.

With no options, prompts for domain/contact, persists cenotoo.env,
renders templates, applies in order, waits for Certificate Ready, runs
legacy cleanup, and prints the endpoint summary.

Self-signed example (no public domain):
  09-expose-api.sh --self-signed --ip 203.0.113.10
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
SELF_SIGNED=false
SELF_SIGNED_IP=""

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
        --self-signed)
            SELF_SIGNED=true
            shift
            ;;
        --ip)
            if [ "$#" -lt 2 ]; then
                fail "--ip requires a value (e.g. --ip 203.0.113.10)."
            fi
            SELF_SIGNED_IP="$2"
            shift 2
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

# ---- Self-signed IP validation (before ANY file writes) -----------------------
# IPv4: dotted-quad shape + octet range 0-255. IPv6: colon-hex form.
_valid_ipv4() {
    local ip="$1"
    case "$ip" in
        *[!0-9.]*) return 1 ;;
    esac
    if ! printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        return 1
    fi
    local o1="$ip" a b c d
    a="${o1%%.*}"; o1="${o1#*.}"; b="${o1%%.*}"; o1="${o1#*.}"
    c="${o1%%.*}"; d="${o1#*.}"
    for o in "$a" "$b" "$c" "$d"; do
        case "$o" in '' | *[!0-9]*) return 1 ;; esac
        if [ "${#o}" -gt 3 ] || [ "$o" -gt 255 ]; then return 1; fi
    done
    return 0
}

_valid_ipv6() {
    local ip="$1"
    case "$ip" in
        *:*)
            case "$ip" in
                *[!0-9A-Fa-f:.]*) return 1 ;;
            esac
            return 0
            ;;
        *) return 1 ;;
    esac
}

if [ "$SELF_SIGNED" = "true" ]; then
    if [ "$FORCE_LEGACY" = "true" ]; then
        fail "--self-signed and --force-legacy-nodeport are mutually exclusive."
    fi
    if [ -z "$SELF_SIGNED_IP" ]; then
        fail "--self-signed requires --ip <addr> (e.g. --self-signed --ip 203.0.113.10)."
    fi
    if ! _valid_ipv4 "$SELF_SIGNED_IP" && ! _valid_ipv6 "$SELF_SIGNED_IP"; then
        fail "--ip '$SELF_SIGNED_IP' is not a valid IPv4/IPv6 address (e.g. 203.0.113.10)."
    fi
    if [ "$NO_WAIT" = "true" ]; then
        warn "--no-wait has no effect with --self-signed (no Certificate Ready wait exists in this mode)."
    fi
fi
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

# ---- Self-signed IP mode (no ACME) -------------------------------------------
# Skips ClusterIssuer/Certificate/Ready-wait/Task-13 entirely. Mints a local
# CA + server cert with SAN IP:<addr> plus the api/dashboard/mqtt DNS names
# for compat, stores it in the shared secret, then applies TLSStore +
# ingresses + IngressRouteTCP only.
if [ "$SELF_SIGNED" = "true" ]; then
    step 2 5 "Mint local CA + server cert (self-signed, IP SAN)"
    require_cmd openssl "Install openssl, then re-run this script."
    SELF_TMP="$(mktemp -d)"
    trap 'rm -rf "$SELF_TMP"' EXIT
    openssl genrsa -out "$SELF_TMP/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$SELF_TMP/ca.key" -sha256 -days 825 \
        -subj "/CN=Cenotoo Local CA" -out "$SELF_TMP/ca.crt"
    openssl genrsa -out "$SELF_TMP/tls.key" 2048 2>/dev/null
    {
        printf '[req]\n'
        printf 'distinguished_name = dn\n'
        printf 'req_extensions = ext\n'
        printf '[dn]\n'
        printf '[ext]\n'
        printf 'subjectAltName = IP:%s,DNS:%s,DNS:%s,DNS:%s\n' \
            "$SELF_SIGNED_IP" "$CENOTOO_API_HOST" "$CENOTOO_DASHBOARD_HOST" "$CENOTOO_MQTT_HOST"
    } > "$SELF_TMP/san.cnf"
    openssl req -new -key "$SELF_TMP/tls.key" -subj "/CN=${SELF_SIGNED_IP}" \
        -config "$SELF_TMP/san.cnf" -out "$SELF_TMP/tls.csr"
    openssl x509 -req -in "$SELF_TMP/tls.csr" -CA "$SELF_TMP/ca.crt" \
        -CAkey "$SELF_TMP/ca.key" -CAcreateserial -days 825 -sha256 \
        -extensions ext -extfile "$SELF_TMP/san.cnf" -out "$SELF_TMP/tls.crt"
    ok "Server cert minted with SAN IP:${SELF_SIGNED_IP} (+ api/dashboard/mqtt DNS)."
    info "Apply: HelmChartConfig (kube-system, Traefik entrypoints) ..."
    kubectl apply -f "$MANIFEST_DIR/00-traefik/helmchartconfig.yaml"
    info "Apply: shared secret cenotoo-public-tls (self-signed) ..."
    kubectl create secret tls cenotoo-public-tls \
        --cert="$SELF_TMP/tls.crt" --key="$SELF_TMP/tls.key" \
        -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    info "Apply: TLSStore/default in $NAMESPACE ..."
    kubectl apply -f "$RENDERED_DIR/00-traefik/tlsstore.yaml" -n "$NAMESPACE"
    info "Apply: API + dashboard ingresses ..."
    kubectl apply -f "$RENDERED_DIR/07-api/ingress.yaml" -n "$NAMESPACE"
    kubectl apply -f "$RENDERED_DIR/08-dashboard/ingress.yaml" -n "$NAMESPACE"
    info "Apply: MQTT IngressRouteTCP ..."
    kubectl apply -f "$RENDERED_DIR/09-mqtt/mqtt-ingressroutetcp.yaml" -n "$NAMESPACE"
    ok "Self-signed manifests applied (no ACME objects created)."
    step 5 5 "Done (self-signed)"
    box \
        "API:   https://${SELF_SIGNED_IP} (Host: ${CENOTOO_API_HOST})" \
        "Docs:  https://${SELF_SIGNED_IP}/docs (Host: ${CENOTOO_API_HOST})" \
        "Dash:  https://${SELF_SIGNED_IP} (Host: ${CENOTOO_DASHBOARD_HOST})" \
        "MQTT:  mqtts://${SELF_SIGNED_IP}:8883 (SNI ${CENOTOO_MQTT_HOST})"
    echo ""
    warn "Self-signed mode: browsers/curl will NOT trust this cert until the local CA is installed."
    dimtext "CA cert: $SELF_TMP/ca.crt (copy it off before the temp dir is removed on exit)"
    dimtext "curl: curl --cacert <ca.crt> https://${SELF_SIGNED_IP}/docs -H 'Host: ${CENOTOO_API_HOST}' -k is NOT recommended"
    dimtext "mqtt: mosquitto_pub --cafile <ca.crt> -h ${SELF_SIGNED_IP} -p 8883 -t test -m hi"
    dimtext "Install the CA in the OS/browser trust store to silence warnings."
    ok "Self-signed IP exposure applied (idempotent — safe to re-run)."
    exit 0
fi

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
