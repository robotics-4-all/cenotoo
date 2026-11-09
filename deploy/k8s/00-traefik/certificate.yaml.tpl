# =============================================================================
# Certificate — ONE shared certificate for all Cenotoo public hosts (Task 5,
# plan tls-ingress-exposure)
# =============================================================================
# Purpose:
#   - Single `Certificate cenotoo-public-tls` in `${CENOTOO_NAMESPACE}`
#     writing the shared secret `${CENOTOO_TLS_SECRET}` (also
#     `cenotoo-public-tls`). The explicit Certificate SOLELY owns the
#     lifecycle (ruling R5): Task 6 Ingresses reference only `secretName`
#     and carry NO `cert-manager.io/cluster-issuer` annotation (competing
#     owners are the failure mode behind risk R-I).
#   - Enumerated SAN list (ruling R1): api, dashboard, mqtt always; coap
#     only when enabled. NO wildcard SAN — HTTP-01 cannot issue one
#     (RFC 8555; risk R-D). No DNS-01 solver anywhere (Task 5 Must NOT).
#   - `rotationPolicy: Always` + `usages: [server auth]` exactly as specified.
#
# COAP CONDITIONAL CONTRACT (Task 9 implements): the line marked
#   `# __CENOTOO_COAP_SAN__` is a placeholder, NOT valid dnsNames content.
#   `scripts/09-expose-api.sh` replaces it with the rendered coap host entry
#   when CENOTOO_COAP_ENABLED is true, and deletes the line otherwise.
#   It must never reach the rendered tree: cenotoo_render_tree only
#   expands allow-listed CENOTOO names, and CENOTOO_COAP_ENABLED is
#   deliberately NOT allow-listed, so a shell conditional is the only
#   correct branching point. Plain render (example values, coap disabled)
#   therefore always yields exactly the api/dashboard/mqtt SAN list.
#   Task 14 asserts exactly one certificate + secret.
#
# MUST NOT (Task 5): per-host secrets, per-host Certificate objects,
#   wildcard entries, hardcoded hosts (every host is a config variable).
#
# RENDER + QA:
#   cenotoo_render_tree deploy/k8s/00-traefik  # -> .rendered/k8s/00-traefik/
#   python3 -c yaml.safe_load on the rendered file (must parse)
#   grep the rendered dnsNames for '*' — must find zero wildcard entries
#   kubectl apply --dry-run=server -f <rendered>  (Task 14, k3s host)
#   kubectl -n cenotoo get certificate cenotoo-public-tls  (READY in 9/14)
# =============================================================================
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cenotoo-public-tls
  namespace: ${CENOTOO_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: cenotoo
spec:
  secretName: ${CENOTOO_TLS_SECRET}
  issuerRef:
    name: cenotoo-letsencrypt
    kind: ClusterIssuer
  commonName: ${CENOTOO_API_HOST}
  dnsNames:
    - ${CENOTOO_API_HOST}
    - ${CENOTOO_DASHBOARD_HOST}
    - ${CENOTOO_MQTT_HOST}
    # __CENOTOO_COAP_SAN__
  rotationPolicy: Always
  usages:
    - server auth
