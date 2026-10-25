#!/usr/bin/env python3
"""
04 — MQTT Subscribe (receiving data from the broker)

Two complementary receive paths exist in Cenotoo:

  A) MQTT subscribe — live messages directly from the Mosquitto broker,
     BEFORE they are bridged to Kafka. Any client subscribed to the same
     topic (or a wildcard) sees messages in real-time. In production the
     go-auth ACL only allows subscribe for the bridge superuser, so this
     example documents both the open-dev and the superuser path.

  B) Kafka / REST consumption — AFTER bridging, messages live in Kafka
     and Cassandra. See 05_kafka_consumer.py (Kafka) and 06_roundtrip.py
     (REST get_data / SSE) for those paths.

This file demonstrates path A: subscribing with paho-mqtt.

Topic wildcards:
    myorg/myproject/sensors     — single collection
    myorg/myproject/+           — all collections in a project
    myorg/+/sensors             — same collection across projects
    myorg/#                     — everything under an org
    #                           — everything (bridge superuser only)

Payload decoding:
    The mqtt-bridge wraps each publish in an envelope before producing to
    Kafka, but subscribers on Mosquitto see the ORIGINAL payload as sent
    by the publisher (no envelope). This example shows how to handle both
    JSON and non-JSON payloads.

Run:
    # Subscribe to one collection (open broker / anonymous):
    python examples/mqtt/04_subscribe.py --topic \"myorg/myproject/sensors\"

    # Wildcard subscribe (requires bridge superuser in production):
    MQTT_USERNAME=cenotoo-bridge MQTT_PASSWORD=<bridge-pass> \\
    python examples/mqtt/04_subscribe.py --topic \"#\"

    # With explicit host:
    MQTT_HOST=192.168.1.50 python examples/mqtt/04_subscribe.py --topic \"myorg/#\"
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import time
import uuid

import paho.mqtt.client as mqtt

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))

_stop = False


def _handle_signal(signum, frame):
    global _stop
    print(f"\n[MAIN] Signal {signum} — disconnecting ...")
    _stop = True


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


def try_json_decode(raw: bytes):
    """Try JSON, fall back to UTF-8 string, then hex."""
    try:
        return json.loads(raw.decode("utf-8")), "json"
    except (json.JSONDecodeError, UnicodeDecodeError):
        pass
    try:
        return raw.decode("utf-8"), "text"
    except UnicodeDecodeError:
        return raw.hex(), "hex"


def main() -> None:
    parser = argparse.ArgumentParser(description="MQTT subscribe example")
    parser.add_argument(
        "--topic", default=None, help="MQTT topic filter (supports + and # wildcards)"
    )
    parser.add_argument("--qos", type=int, default=1, choices=[0, 1], help="Subscribe QoS")
    parser.add_argument(
        "--pretty", action="store_true", default=True, help="Pretty-print JSON payloads"
    )
    parser.add_argument(
        "--raw", action="store_true", help="Print raw payload bytes without decoding"
    )
    args = parser.parse_args()

    org = os.getenv("ORG", "myorg")
    project = os.getenv("PROJECT", "myproject")
    collection = os.getenv("COLLECTION", "sensors")
    topic_filter = args.topic or f"{org}/{project}/{collection}"

    username = os.getenv("MQTT_USERNAME", "")
    password = os.getenv("MQTT_PASSWORD", "")

    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"cenotoo-sub-{uuid.uuid4().hex[:6]}",
    )
    if username and password:
        client.username_pw_set(username, password)
        print(f"[MQTT] Authenticating as '{username}'")

    # Optional TLS:
    # if os.getenv("MQTT_USE_TLS", "false").lower() in ("1", "true"):
    #     import ssl
    #     client.tls_set(ca_certs=os.getenv("MQTT_CA_CERT"), tls_version=ssl.PROTOCOL_TLSv1_2)

    received = 0

    def on_connect(cli, userdata, flags, reason_code, properties=None):
        if reason_code == 0:
            print(f"[MQTT] Connected to {MQTT_HOST}:{MQTT_PORT}")
            # Subscribe inside on_connect so reconnects re-subscribe automatically
            result, mid = cli.subscribe(topic_filter, qos=args.qos)
            if result == mqtt.MQTT_ERR_SUCCESS:
                print(
                    f"[MQTT] Subscribed to '{topic_filter}' (QoS {args.qos}) — waiting for messages ..."
                )
                print("       Publish something to test, e.g.:")
                print(
                    f"         mosquitto_pub -h {MQTT_HOST} -p {MQTT_PORT} "
                    f'-t "{org}/{project}/{collection}" -m \'{{"temp": 22.5}}\''
                )
            else:
                print(f"[MQTT] Subscribe failed rc={result}")
        else:
            print(f"[MQTT] Connect failed reason_code={reason_code}")
            if reason_code == 4:
                print("       → Bad credentials. Check MQTT_USERNAME / MQTT_PASSWORD.")
            elif reason_code == 5:
                print(
                    "       → Not authorised. Regular project keys can only PUBLISH, not subscribe."
                )
                print(
                    "         Use bridge superuser credentials to subscribe, or consume via Kafka/REST instead."
                )
                print("         See 05_kafka_consumer.py for the Kafka receive path.")

    def on_subscribe(cli, userdata, mid, granted_qos, properties=None):
        print(f"[MQTT] Subscription confirmed (mid={mid}, granted_qos={granted_qos})")

    def on_message(cli, userdata, msg):
        nonlocal received
        received += 1
        ts = time.strftime("%Y-%m-%d %H:%M:%S")

        if args.raw:
            print(f"[{ts}] topic={msg.topic}  qos={msg.qos}  payload={msg.payload!r}")
            return

        payload, kind = try_json_decode(msg.payload)

        print(f"[{ts}] topic={msg.topic}  qos={msg.qos}  kind={kind}  #{received}")
        if kind == "json":
            if args.pretty:
                print(json.dumps(payload, indent=2, ensure_ascii=False))
            else:
                print(json.dumps(payload, ensure_ascii=False))
        else:
            print(f"  payload: {payload}")
        print("-" * 60)

    def on_disconnect(cli, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            print(
                f"[MQTT] Disconnected unexpectedly rc={reason_code} — will auto-reconnect if loop is running"
            )

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    client.on_disconnect = on_disconnect

    # Auto-reconnect with back-off
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    print(f"[MQTT] Connecting to {MQTT_HOST}:{MQTT_PORT}  filter='{topic_filter}'")
    try:
        client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    except Exception as exc:
        print(f"[MQTT] Connection error: {exc}")
        print(
            "       Is the broker reachable? Try: kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo"
        )
        raise SystemExit(1) from exc

    client.loop_start()

    print("[SUBSCRIBE] Listening — press Ctrl+C to stop")
    try:
        while not _stop:
            time.sleep(0.5)
    finally:
        client.loop_stop()
        client.disconnect()
        print(f"[MQTT] Done — received {received} message(s)")


if __name__ == "__main__":
    main()
