# =============================================================================
# IngressRouteTCP — public MQTT over TLS on entrypoint mqtts (Task 7, plan
# tls-ingress-exposure)
# =============================================================================
# Purpose:
#   - Terminate TLS at Traefik on `mqtts:8883` (Task 2 entrypoint) with the
#     shared secret `${CENOTOO_TLS_SECRET}` (`cenotoo-public-tls`, Task 5);
#     forward PLAINTEXT to `cenotoo-mosquitto:1883` (fixed decision 3).
#   - Route 1 (strict, priority 100): `HostSNI(mqtt host)` for clients that
#     send SNI — the only route where hostname verification is meaningful.
#   - Route 2 (catch-all, priority 1): `HostSNI(*)` so mixed-SNI fleet
#     clients that send no SNI still complete TLS (ruling R6: tls.secretName
#     on every router covers SNI-less traffic).
#
# RENDER: deploy/k8s/09-mqtt/ -> .rendered/k8s/09-mqtt/ via
#   cenotoo_render_tree (Task 9 apply order: ..., ingresses, IngressRouteTCP).
#
# MUST NOT (Task 7): Mosquitto TLS listener, broker configmap/StatefulSet
#   edits, hardcoded domains (host + secretName are config variables only).
#
# QA (Task 14, on the k3s host):
#   kubectl -n cenotoo get ingressroutetcp cenotoo-mqtt -o yaml  # 2 routes
#   openssl s_client -connect $CENOTOO_MQTT_HOST:8883 -servername $CENOTOO_MQTT_HOST
#   openssl s_client -connect $CENOTOO_MQTT_HOST:8883  # no SNI, still TLS
# =============================================================================
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: cenotoo-mqtt
  namespace: ${CENOTOO_NAMESPACE}
  labels:
    app.kubernetes.io/component: mqtt-broker
    app.kubernetes.io/part-of: cenotoo
spec:
  entryPoints:
    - mqtts
  routes:
    - match: HostSNI(`${CENOTOO_MQTT_HOST}`)
      priority: 100
      services:
        - name: cenotoo-mosquitto
          port: 1883
    - match: HostSNI(`*`)
      priority: 1
      services:
        - name: cenotoo-mosquitto
          port: 1883
  tls:
    secretName: ${CENOTOO_TLS_SECRET}
