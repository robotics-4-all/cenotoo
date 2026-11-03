#!/usr/bin/env python3
"""
05 — Kafka Consumer (receiving data AFTER MQTT bridging)

After the mqtt-bridge forwards a message to Kafka, it is available to any
Kafka consumer subscribed to the topic  \"{org}.{project}.{collection}\".
This is the primary \"receive\" path for backend services, analytics jobs,
and any system that needs reliable, replayable access to ingested data.

What the consumer actually sees:
    The bridge produces an ENVELOPE (not the raw payload):

    {
        \"mqtt_topic\": \"myorg/myproject/sensors\",
        \"payload\": { \"temperature\": 22.5, ... },   # original JSON or string/hex
        \"ts\": 1715000000000,                        # bridge epoch ms
        \"client_id\": \"cenotoo-bridge\"
    }

    The Kafka record value is JSON-encoded envelope bytes.
    Headers / key are not set by the bridge.

Kafka topic naming:
    MQTT  myorg/myproject/sensors  →  Kafka  myorg.myproject.sensors
    (slashes become dots, exactly three segments required)

This example mirrors kafka-live-consumer/consumer.py but adds:
  - Envelope decoding with pretty output
  - --from-beginning flag to replay history
  - SASL/PLAIN support for production Kafka
  - Graceful shutdown and offset handling

Prerequisites:
    pip install -r requirements.txt

    Kafka must be reachable. In k8s:
        kubectl port-forward svc/cenotoo-kafka-kafka-bootstrap 9092:9092 -n cenotoo
    Or use the broker address from deploy/k8s/02-kafka/kafka-cluster.yaml

Run:
    # Live tail (latest messages only — like `kafka-live-consumer`):
    python examples/mqtt/05_kafka_consumer.py

    # Replay all history:
    python examples/mqtt/05_kafka_consumer.py --from-beginning

    # Specific topic:
    python examples/mqtt/05_kafka_consumer.py --topic myorg.myproject.sensors

    # With SASL (production):
    KAFKA_USERNAME=myuser KAFKA_PASSWORD=mypass python examples/mqtt/05_kafka_consumer.py

    # Keep running and print each message as it arrives — publish from another
    # terminal with 01_basic_publish.py to see the round-trip.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import uuid

from confluent_kafka import Consumer, KafkaError

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_USERNAME = os.getenv("KAFKA_USERNAME", "")
KAFKA_PASSWORD = os.getenv("KAFKA_PASSWORD", "")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "PLAIN")

ORG = os.getenv("ORG", "myorg")
PROJECT = os.getenv("PROJECT", "myproject")
COLLECTION = os.getenv("COLLECTION", "sensors")
DEFAULT_TOPIC = f"{ORG}.{PROJECT}.{COLLECTION}"

_shutdown = False


def _handle_signal(signum, frame):
    global _shutdown
    print(f"\n[CONSUMER] Signal {signum} — shutting down ...")
    _shutdown = True


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


def build_consumer_config(group_id: str, from_beginning: bool) -> dict:
    cfg: dict = {
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": group_id,
        "auto.offset.reset": "earliest" if from_beginning else "latest",
        "enable.auto.commit": True,
        "auto.commit.interval.ms": 1000,
    }
    if KAFKA_USERNAME and KAFKA_PASSWORD:
        cfg.update(
            {
                "security.protocol": KAFKA_SECURITY_PROTOCOL,
                "sasl.mechanism": KAFKA_SASL_MECHANISM,
                "sasl.username": KAFKA_USERNAME,
                "sasl.password": KAFKA_PASSWORD,
            }
        )
    return cfg


def decode_envelope(raw: bytes) -> dict:
    """Decode the bridge envelope; fall back to raw display on failure."""
    try:
        env = json.loads(raw.decode("utf-8"))
        return env
    except Exception:
        try:
            return {"_raw": raw.decode("utf-8"), "_decode": "text"}
        except UnicodeDecodeError:
            return {"_raw": raw.hex(), "_decode": "hex"}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Kafka consumer — receive path for MQTT-ingested data"
    )
    parser.add_argument(
        "--topic", default=DEFAULT_TOPIC, help="Kafka topic (default: {org}.{project}.{collection})"
    )
    parser.add_argument(
        "--from-beginning",
        action="store_true",
        help="Replay from earliest offset instead of live tail",
    )
    parser.add_argument("--group", default=None, help="Consumer group id (default: random)")
    parser.add_argument(
        "--timeout",
        type=float,
        default=0,
        help="Stop after N seconds of no messages (0 = run forever)",
    )
    parser.add_argument(
        "--max-messages", type=int, default=0, help="Stop after N messages (0 = unlimited)"
    )
    args = parser.parse_args()

    group_id = args.group or f"mqtt-example-consumer-{uuid.uuid4().hex[:6]}"
    cfg = build_consumer_config(group_id, args.from_beginning)

    print(f"[KAFKA] Bootstrap: {KAFKA_BOOTSTRAP}")
    print(f"[KAFKA] Topic:     {args.topic}")
    print(
        f"[KAFKA] Group:     {group_id}  (offset: {'earliest' if args.from_beginning else 'latest'})"
    )
    if KAFKA_USERNAME:
        print(
            f"[KAFKA] SASL:      {KAFKA_SASL_MECHANISM} / {KAFKA_SECURITY_PROTOCOL} as {KAFKA_USERNAME}"
        )

    consumer = Consumer(cfg)
    consumer.subscribe([args.topic])
    print("[KAFKA] Subscribed — waiting for messages (Ctrl+C to stop)")
    if not args.from_beginning:
        print(
            "        Tip: publish with 01_basic_publish.py from another terminal to see messages arrive."
        )
    print("-" * 70)

    received = 0
    last_msg_time = time.time()

    try:
        while not _shutdown:
            msg = consumer.poll(1.0)
            if msg is None:
                # No message within poll interval
                if args.timeout and (time.time() - last_msg_time) > args.timeout:
                    print(f"[KAFKA] No messages for {args.timeout}s — stopping (--timeout)")
                    break
                continue

            if msg.error():
                code = msg.error().code()
                if code == KafkaError._PARTITION_EOF:
                    continue
                if code == KafkaError.UNKNOWN_TOPIC_OR_PART:
                    print(
                        f"[KAFKA] Topic '{args.topic}' does not exist yet — "
                        f"publish a message first (it will be auto-created). Retrying ..."
                    )
                    time.sleep(3)
                    continue
                print(f"[KAFKA] Error: {msg.error()}", file=sys.stderr)
                continue

            received += 1
            last_msg_time = time.time()

            envelope = decode_envelope(msg.value())
            ts = envelope.get("ts")
            ts_str = (
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts / 1000))
                if isinstance(ts, int)
                else "n/a"
            )

            print(f"[{received:4d}] partition={msg.partition()} offset={msg.offset()}  ts={ts_str}")
            print(f"       mqtt_topic: {envelope.get('mqtt_topic', 'n/a')}")
            print(f"       client_id:  {envelope.get('client_id', 'n/a')}")

            payload = envelope.get("payload", envelope.get("_raw", envelope))
            if isinstance(payload, dict):
                print(f"       payload: {json.dumps(payload, indent=6, ensure_ascii=False)}")
            else:
                print(f"       payload: {payload!r}")
            print("-" * 70)

            if args.max_messages and received >= args.max_messages:
                print(f"[KAFKA] Reached --max-messages={args.max_messages} — stopping")
                break

    finally:
        print(f"[KAFKA] Closing consumer (received {received} message(s)) ...")
        consumer.close()
        print("[KAFKA] Done.")


if __name__ == "__main__":
    main()
