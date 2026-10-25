#!/usr/bin/env python3
"""
03 — Batch / High-throughput Publish

Demonstrates:
  - Publishing a burst of messages in a tight loop
  - QoS 0 vs QoS 1 trade-offs
  - Re-using a single MQTT connection for many publishes
  - Simulating multiple devices with different payloads
  - Throttling with a configurable publish interval
  - Graceful handling of back-pressure / queued messages

Useful for load-testing the MQTT → Kafka → Cassandra pipeline or for
simulating a fleet of sensors that report every few seconds.

Run:
    python examples/mqtt/03_batch_publish.py --count 50 --interval 0.1
    python examples/mqtt/03_batch_publish.py --count 1000 --qos 0 --interval 0.01
    MQTT_HOST=192.168.1.50 python examples/mqtt/03_batch_publish.py --count 20
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import time
import uuid

import paho.mqtt.client as mqtt

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
ORG = os.getenv("ORG", "myorg")
PROJECT = os.getenv("PROJECT", "myproject")
COLLECTION = os.getenv("COLLECTION", "sensors")

_stop = False


def _handle_signal(signum, frame):
    global _stop
    print(f"\n[MAIN] Signal {signum} — stopping after current message ...")
    _stop = True


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


def make_payload(device_id: str, seq: int) -> dict:
    """Generate a realistic sensor reading with small random variation."""
    return {
        "sensor_id": device_id,
        "seq": seq,
        "temperature": round(20 + random.uniform(-3, 5), 2),
        "humidity": round(55 + random.uniform(-10, 10), 1),
        "pressure": round(1013 + random.uniform(-8, 8), 1),
        "battery": round(3.7 + random.uniform(-0.2, 0.1), 2),
        "ts": int(time.time() * 1000),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Batch MQTT publish example")
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        help="Number of messages to publish (0 = infinite until Ctrl+C)",
    )
    parser.add_argument("--interval", type=float, default=0.2, help="Seconds between publishes")
    parser.add_argument("--qos", type=int, default=1, choices=[0, 1], help="MQTT QoS level")
    parser.add_argument(
        "--devices", type=int, default=3, help="Number of simulated device IDs to rotate"
    )
    parser.add_argument("--topic", default=None, help="Override MQTT topic")
    args = parser.parse_args()

    topic = args.topic or f"{ORG}/{PROJECT}/{COLLECTION}"
    device_ids = [f"sensor-{i:02d}" for i in range(1, args.devices + 1)]

    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"cenotoo-batch-{uuid.uuid4().hex[:6]}",
    )

    # Optional auth
    username = os.getenv("MQTT_USERNAME", "")
    password = os.getenv("MQTT_PASSWORD", "")
    if username and password:
        client.username_pw_set(username, password)

    acked = 0
    failed = 0
    pending: list = []

    def on_publish(cli, userdata, mid, reason_code=None, properties=None):
        nonlocal acked
        acked += 1

    def on_disconnect(cli, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            print(f"[MQTT] Disconnect rc={reason_code}")

    client.on_publish = on_publish
    client.on_disconnect = on_disconnect

    print(f"[MQTT] Connecting to {MQTT_HOST}:{MQTT_PORT}  topic='{topic}'  qos={args.qos}")
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()
    time.sleep(0.8)  # CONNACK

    print(
        f"[PUBLISH] Sending {args.count if args.count else '∞'} messages "
        f"every {args.interval}s across {args.devices} device(s) — Ctrl+C to stop"
    )
    print("-" * 60)

    sent = 0
    start = time.time()

    try:
        while not _stop:
            if args.count and sent >= args.count:
                break

            device = random.choice(device_ids)
            payload = make_payload(device, sent + 1)
            payload_str = json.dumps(payload)

            result = client.publish(topic, payload_str, qos=args.qos)
            sent += 1

            if args.qos == 1:
                # For QoS 1 we can optionally wait; here we fire-and-forget
                # and let on_publish count acks asynchronously.
                pending.append(result)
                # Prune completed
                pending = [r for r in pending if not r.is_published()]
            else:
                # QoS 0 — no ack, just check rc
                if result.rc != mqtt.MQTT_ERR_SUCCESS:
                    failed += 1

            print(
                f"  [{sent:4d}] {device}  temp={payload['temperature']:5.1f}°C  "
                f"hum={payload['humidity']:4.1f}%  → mid={result.mid}"
            )

            if args.interval > 0:
                time.sleep(args.interval)

            # Periodic stats
            if sent % 20 == 0:
                elapsed = time.time() - start
                rate = sent / elapsed if elapsed > 0 else 0
                print(
                    f"  -- {sent} sent, {acked} acked, {len(pending)} pending, {rate:.1f} msg/s --"
                )

    finally:
        # Wait for pending QoS 1 acks
        if args.qos == 1 and pending:
            print(f"[PUBLISH] Waiting for {len(pending)} pending acks ...")
            for r in pending:
                try:
                    r.wait_for_publish(timeout=3)
                except RuntimeError:
                    failed += 1

        time.sleep(0.3)
        client.loop_stop()
        client.disconnect()

        elapsed = time.time() - start
        rate = sent / elapsed if elapsed > 0 else 0
        print("-" * 60)
        print(
            f"[DONE] Sent={sent}  Acked={acked}  Failed={failed}  "
            f"Elapsed={elapsed:.1f}s  Rate={rate:.1f} msg/s"
        )
        print(f"       Kafka topic: {ORG}.{PROJECT}.{COLLECTION}")
        print("       Verify: check Cassandra row count or Kafka consumer lag.")


if __name__ == "__main__":
    main()
