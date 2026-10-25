#!/usr/bin/env bash
# =============================================================================
# Cenotoo MQTT — shell examples with mosquitto_pub / mosquitto_sub
#
# These are the quickest way to test ingestion without writing code.
# Install mosquitto clients if needed:
#   sudo apt-get install mosquitto-clients   # Debian/Ubuntu
#   brew install mosquitto                   # macOS
#
# If the broker runs inside k3s, expose it first:
#   kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo
#
# Then set BROKER to localhost (default below) or to the k8s node IP.
# =============================================================================
set -euo pipefail

BROKER="${MQTT_HOST:-localhost}"
PORT="${MQTT_PORT:-1883}"

# Auth (production with go-auth):
#   export MQTT_USERNAME="<project-uuid>"
#   export MQTT_PASSWORD="<write-scoped-api-key>"
AUTH_ARGS=()
if [[ -n "${MQTT_USERNAME:-}" && -n "${MQTT_PASSWORD:-}" ]]; then
  AUTH_ARGS=(-u "$MQTT_USERNAME" -P "$MQTT_PASSWORD")
fi

ORG="${ORG:-myorg}"
PROJECT="${PROJECT:-myproject}"
COLLECTION="${COLLECTION:-sensors}"
TOPIC="$ORG/$PROJECT/$COLLECTION"

echo "Broker: $BROKER:$PORT  Topic: $TOPIC"
echo ""

# ---------------------------------------------------------------------------
# 1. Single JSON publish (the canonical example from the README)
# ---------------------------------------------------------------------------
echo "--- 1. Single JSON publish ---"
mosquitto_pub -h "$BROKER" -p "$PORT" "${AUTH_ARGS[@]}" \
  -t "$TOPIC" \
  -m '{"temp": 22.5, "humidity": 58, "node": "roof-01"}' \
  -q 1
echo "✓ Published single JSON payload"
echo ""

# ---------------------------------------------------------------------------
# 2. Publish with all sensor fields (richer payload)
# ---------------------------------------------------------------------------
echo "--- 2. Rich sensor payload ---"
mosquitto_pub -h "$BROKER" -p "$PORT" "${AUTH_ARGS[@]}" \
  -t "$TOPIC" \
  -m "{\"sensor_id\": \"lab-01\", \"temperature\": 24.3, \"humidity\": 61.2, \"pressure\": 1012.8, \"ts\": $(date +%s)000}" \
  -q 1
echo "✓ Published rich payload"
echo ""

# ---------------------------------------------------------------------------
# 3. Non-JSON payload (plain string — bridge wraps as string, not object)
# ---------------------------------------------------------------------------
echo "--- 3. Non-JSON payload (plain string) ---"
mosquitto_pub -h "$BROKER" -p "$PORT" "${AUTH_ARGS[@]}" \
  -t "$TOPIC" \
  -m 'hello from shell' \
  -q 1
echo "✓ Published plain-string payload (envelope.payload will be a string)"
echo ""

# ---------------------------------------------------------------------------
# 4. Batch — publish 5 messages in a loop
# ---------------------------------------------------------------------------
echo "--- 4. Batch publish (5 messages) ---"
for i in $(seq 1 5); do
  TEMP=$(awk -v seed="$RANDOM" 'BEGIN { srand(seed); printf "%.1f", 20+rand()*6 }')
  mosquitto_pub -h "$BROKER" -p "$PORT" "${AUTH_ARGS[@]}" \
    -t "$TOPIC" \
    -m "{\"sensor_id\": \"shell-batch\", \"seq\": $i, \"temperature\": $TEMP, \"ts\": $(date +%s)000}" \
    -q 1
  echo "  [$i/5] temp=$TEMP °C"
  sleep 0.2
done
echo "✓ Batch done"
echo ""

# ---------------------------------------------------------------------------
# 5. Subscribe and watch live (run in a separate terminal, or background)
# ---------------------------------------------------------------------------
echo "--- 5. Subscribe example (5-second capture) ---"
echo "    Subscribing to '$TOPIC' for 5 seconds — publish from another shell to see it live."
echo "    Command: mosquitto_sub -h $BROKER -p $PORT -t \"$TOPIC\" -v"
echo ""

# Only try to subscribe if we use bridge superuser (regular project keys cannot subscribe — ACL deny)
if [[ "${MQTT_USERNAME:-}" == "cenotoo-bridge" ]]; then
  timeout 5 mosquitto_sub -h "$BROKER" -p "$PORT" "${AUTH_ARGS[@]}" -t "$TOPIC" -v || true
else
  echo "    (Skipped live capture — regular project API keys can only publish, not subscribe.)"
  echo "    To test subscribe, use bridge superuser:"
  echo "      MQTT_USERNAME=cenotoo-bridge MQTT_PASSWORD=\$(kubectl get secret cenotoo-mqtt-credentials -n cenotoo -o jsonpath='{.data.password}' | base64 -d) \\"
  echo "      mosquitto_sub -h $BROKER -p $PORT -u \"\$MQTT_USERNAME\" -P \"\$MQTT_PASSWORD\" -t \"#\" -v"
  echo ""
  echo "    Alternative receive paths (no MQTT subscribe needed):"
  echo "      python examples/mqtt/05_kafka_consumer.py --topic $ORG.$PROJECT.$COLLECTION"
  echo "      curl -H 'X-API-Key: <read-key>' $CENOTOO_API_URL/projects/<pid>/collections/<cid>/get_data"
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Invalid topic (wrong segment count) — will be silently dropped by bridge
# ---------------------------------------------------------------------------
echo "--- 6. Invalid topic (demonstrates 3-segment validation) ---"
echo "    Publishing to 'myorg/myproject' (only 2 segments) — bridge will skip it."
mosquitto_pub -h "$BROKER" -p "$PORT" "${AUTH_ARGS[@]}" \
  -t "myorg/myproject" \
  -m '{"oops": true}' \
  -q 1 || true
echo "    Check mqtt-bridge logs: kubectl logs deploy/cenotoo-mqtt-bridge -n cenotoo"
echo "    Expected: \"Skipping invalid MQTT topic (expected exactly 3 segments)\""
echo ""

# ---------------------------------------------------------------------------
# 7. TLS publish (if broker exposes 8883 with TLS — uncomment and configure)
# ---------------------------------------------------------------------------
# echo "--- 7. TLS publish (port 8883) ---"
# mosquitto_pub -h "$BROKER" -p 8883 \
#   --cafile /path/to/ca.crt \
#   -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
#   -t "$TOPIC" \
#   -m '{"secure": true, "temp": 21.0}' \
#   -q 1
# echo "✓ Published over TLS"
# echo ""

echo "All shell examples done."
echo ""
echo "Verify ingestion:"
echo "  Kafka:  kubectl exec -n cenotoo cenotoo-kafka-kafka-0 -- bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic $ORG.$PROJECT.$COLLECTION --from-beginning --max-messages 5"
echo "  CQL:    SELECT * FROM $ORG.${PROJECT}_${COLLECTION} LIMIT 5;"
echo "  REST:   curl -H 'X-API-Key: <key>' http://localhost:8000/projects/<pid>/collections/<cid>/get_data"
