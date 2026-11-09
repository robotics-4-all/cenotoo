apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cenotoo-dashboard
  labels:
    app.kubernetes.io/component: dashboard
    app.kubernetes.io/part-of: cenotoo
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ${CENOTOO_DASHBOARD_HOST}
      secretName: ${CENOTOO_TLS_SECRET}
  rules:
    - host: ${CENOTOO_DASHBOARD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cenotoo-dashboard
                port:
                  name: http
