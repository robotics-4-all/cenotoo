#!/usr/bin/env bash
set -euo pipefail
# Applies Traefik mqtts entrypoint (HelmChartConfig), MQTT TLS
# certificate and IngressRouteTCP. Idempotent: kubectl apply only.
# Prerequisites: Traefik (k3s default), cert-manager + cenotoo-letsencrypt
# ClusterIssuer (scripts/09-expose-api.sh), DNS mqtt.<domain> -> node IP.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${CENOTOO_NAMESPACE:-cenotoo}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "Applying Traefik mqtts HelmChartConfig (kube-system) ..."
kubectl apply -f "$PROJECT_DIR/deploy/k8s/00-traefik/traefik-mqtts-config.yaml"
echo "Applying MQTT Certificate + IngressRouteTCP ($NAMESPACE) ..."
kubectl apply -n "$NAMESPACE" -f "$PROJECT_DIR/deploy/k8s/09-mqtt/mqtt-certificate.yaml"
kubectl apply -n "$NAMESPACE" -f "$PROJECT_DIR/deploy/k8s/09-mqtt/mosquitto-tls-tcproute.yaml"
echo "Waiting for certificate cenotoo-mqtt-tls ..."
kubectl wait --for=condition=Ready certificate/cenotoo-mqtt-tls -n "$NAMESPACE" --timeout=180s
echo "MQTT TLS route ready: mqtts :8883 -> cenotoo-mosquitto:1883"
