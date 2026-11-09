# =============================================================================
# TLSStore — cluster-wide default TLS fallback for Traefik (Task 5, plan
# tls-ingress-exposure)
# =============================================================================
# Purpose:
#   - `TLSStore/default` pointing at the shared secret
#     `${CENOTOO_NAMESPACE}/${CENOTOO_TLS_SECRET}` (`cenotoo-public-tls`),
#     so SNI-less traffic still terminates with the right certificate
#     (ruling R6). Belt and braces with `tls.secretName` on every router
#     (Tasks 6/7): both cover SNI and non-SNI handshakes.
#
# NAMESPACE NOTE (ruling R6): TLSStore is namespace-scoped. This object
#   MUST live in `${CENOTOO_NAMESPACE}` — the same namespace as the secret
#   and every router — because `secretName` here is resolved as
#   `<this-namespace>/<name>`. Do not move it to kube-system.
#
# RENDER: deploy/k8s/00-traefik/ -> .rendered/k8s/00-traefik/ via
#   cenotoo_render_tree (Task 9 apply order: HelmChartConfig, ClusterIssuer,
#   TLSStore, Certificate, ingresses, IngressRouteTCP).
#
# MUST NOT (Task 5): per-host stores, hardcoded secret names, wildcard refs.
#
# QA (Task 14, on the k3s host):
#   kubectl apply --dry-run=server -f .rendered/k8s/00-traefik/tlsstore.yaml
#   kubectl -n cenotoo get tlsstore default -o yaml  # expect secretName set
# =============================================================================
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: ${CENOTOO_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: cenotoo
spec:
  defaultCertificate:
    secretName: ${CENOTOO_TLS_SECRET}
