apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cenotoo-api
  labels:
    app.kubernetes.io/component: api
    app.kubernetes.io/part-of: cenotoo
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ${CENOTOO_API_HOST}
      secretName: ${CENOTOO_TLS_SECRET}
  rules:
    - host: ${CENOTOO_API_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cenotoo-api
                port:
                  name: http
