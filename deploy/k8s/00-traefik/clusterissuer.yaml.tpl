# =============================================================================
# ClusterIssuer — ACME account for Cenotoo public TLS (Task 5, plan
# tls-ingress-exposure)
# =============================================================================
# Purpose:
#   - Single ACME issuer `cenotoo-letsencrypt` used by the shared
#     `Certificate cenotoo-public-tls` (certificate.yaml.tpl). HTTP-01 only;
#     the solver targets `ingressClassName: traefik` so cert-manager answers
#     challenges through Traefik (ruling R2: the web->websecure redirect
#     keeps `/.well-known/acme-challenge/*` on plain HTTP via allowACMEByPass).
#   - `server` and `email` come from config (`deploy/k8s/cenotoo.env`):
#     staging-capable — point CENOTOO_ACME_SERVER at the Let's Encrypt
#     staging directory until DNS + port 80 validate (risk R-C), then switch
#     to production. Never hardcode the directory here.
#
# RENDER: deploy/k8s/00-traefik/ -> .rendered/k8s/00-traefik/ via
#   cenotoo_render_tree (Task 9 apply order: HelmChartConfig, ClusterIssuer,
#   TLSStore, Certificate, ingresses, IngressRouteTCP).
#
# MUST NOT (Task 5): DNS-01 solver, wildcard issuance, per-host issuers.
# Cleanup (Task 13) deletes `clusterissuer cenotoo-letsencrypt` with
# --ignore-not-found; never delete it while the Certificate exists.
#
# QA (Task 14, on the k3s host):
#   kubectl apply --dry-run=server -f .rendered/k8s/00-traefik/clusterissuer.yaml
#   kubectl get clusterissuer cenotoo-letsencrypt -o wide  # expect Ready True
# =============================================================================
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cenotoo-letsencrypt
  labels:
    app.kubernetes.io/part-of: cenotoo
spec:
  acme:
    server: ${CENOTOO_ACME_SERVER}
    email: ${CENOTOO_TLS_EMAIL}
    privateKeySecretRef:
      name: cenotoo-letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
