#!/usr/bin/env python3
"""
01 — Basic MQTT Publish (anonymous / local-dev)

Sends a single JSON payload to Cenotoo via the Mosquitto broker.

Topic convention:
    MQTT topic  \"{org}/{project}/{collection}\"
        → Kafka topic  \"{org}.{project}.{collection}\"
        → Cassandra    keyspace \"{org}\", table \"{project}_{collection}\"

The mqtt-bridge subscribes to `#`, validates that the topic has exactly
three non-empty segments, wraps the payload in an envelope and produces
it to Kafka:

    envelope = {
        \"mqtt_topic\": \"myorg/myproject/sensors\",
        \"payload\":    { ... your JSON ... },
        \"ts\":         1715000000000,          # bridge-side epoch ms
        \"client_id\":  \"cenotoo-bridge\"
    }

Prerequisites:
    pip install -r requirements.txt

    # If the broker runs inside k3s, expose it locally:
    kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo

    # Optionally override via env vars:
    MQTT_HOST=localhost MQTT_PORT=1883 python examples/mqtt/01_basic_publish.py

Run:
    python examples/mqtt/01_basic_publish.py
"""

from __future__ import annotations

import json
import os
import time
import uuid

import paho.mqtt.client as mqtt

# ---------------------------------------------------------------------------
# Config — override with env vars or edit inline
# ---------------------------------------------------------------------------
MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
ORG = os.getenv("ORG", "myorg")
PROJECT = os.getenv("PROJECT", "myproject")
COLLECTION = os.getenv("COLLECTION", "sensors")

TOPIC = f"{ORG}/{PROJECT}/{COLLECTION}"

# Example sensor payload — any JSON-serialisable dict is accepted.
# Non-JSON payloads are also accepted (wrapped as raw string / hex) but
# JSON is recommended so the Cassandra writer can create typed columns.
PAYLOAD = {
    "sensor_id": "roof-01",
    "temperature": 22.5,
    "humidity": 58,
    "pm2_5": 7.3,
    "timestamp": int(time.time() * 1000),
    "location": {"lat": 37.98, "lon": 23.72},
}


# ---------------------------------------------------------------------------
# MQTT callbacks (paho-mqtt v2 API)
# ---------------------------------------------------------------------------
def on_connect(client, userdata, flags, reason_code, properties=None):
    if reason_code == 0:
        print(f"[MQTT] Connected to {MQTT_HOST}:{MQTT_PORT}")
    else:
        print(f"[MQTT] Connection failed — reason_code={reason_code}")


def on_publish(client, userdata, mid, reason_code=None, properties=None):
    print(f"[MQTT] Publish acknowledged (mid={mid})")


def on_disconnect(client, userdata, flags, reason_code, properties=None):
    if reason_code != 0:
        print(f"[MQTT] Unexpected disconnect — reason_code={reason_code}")


def main() -> None:
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"cenotoo-example-pub-{uuid.uuid4().hex[:6]}",
    )
    client.on_connect = on_connect
    client.on_publish = on_publish
    client.on_disconnect = on_disconnect

    # Optional auth — only needed when the Mosquitto go-auth plugin is active.
    username = os.getenv("MQTT_USERNAME", "")
    password = os.getenv("MQTT_PASSWORD", "")
    if username and password:
        client.username_pw_set(username, password)
        print(f"[MQTT] Using credentials user={username}")

    # Optional TLS (uncomment if your broker exposes 8883 with TLS):
    # if os.getenv("MQTT_USE_TLS", "false").lower() in ("1", "true", "yes"):
    #     import ssl
    #     ca_cert = os.getenv("MQTT_CA_CERT")
    #     client.tls_set(ca_certs=ca_cert, tls_version=ssl.PROTOCOL_TLSv1_2)

    print(f"[MQTT] Connecting to {MQTT_HOST}:{MQTT_PORT} ...")
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()

    # Wait for CONNACK
    time.sleep(1)

    payload_str = json.dumps(PAYLOAD)
    print(f"[MQTT] Publishing to topic '{TOPIC}':")
    print(f"       {payload_str}")

    result = client.publish(TOPIC, payload_str, qos=1)
    result.wait_for_publish(timeout=5)

    if result.is_published():
        print("[MQTT] ✓ Message published (QoS 1 acknowledged)")
    else:
        print("[MQTT] ✗ Publish not acknowledged — check broker connectivity")

    # Brief grace period so the broker can flush, then clean shutdown
    time.sleep(0.5)
    client.loop_stop()
    client.disconnect()
    print("[MQTT] Disconnected. Check Cassandra / Kafka for the message:")
    print(f"       Kafka topic: {ORG}.{PROJECT}.{COLLECTION}")
    print(f"       CQL: SELECT * FROM {ORG}.{PROJECT}_{COLLECTION} LIMIT 10;")


if __name__ == "__main__":
    main()
