#!/usr/bin/env python3
"""
06 — End-to-end Round-trip: Publish via MQTT → Verify via REST + Kafka

Publishes a uniquely identifiable message over MQTT and then confirms
it arrived by polling both:
  1. Kafka consumer (direct, low latency)
  2. REST API get_data (via Cassandra — eventual, ~1-2s delay)

This is the recommended pattern for integration tests and health checks.

Flow:
    [this script] --MQTT publish--> [Mosquitto] --> [mqtt-bridge]
        --> [Kafka: myorg.myproject.sensors] --> [kafka-to-cassandra]
        --> [Cassandra: myorg.myproject_sensors]
        --> [REST API: GET /get_data]

    Verification:
        - Kafka: subscribe with a fresh consumer group from 'latest' before
          publishing, wait for the envelope with the expected marker.
        - REST:  GET /projects/{pid}/collections/{cid}/get_data?filter=...

Prerequisites:
    pip install -r requirements.txt

    All services port-forwarded (or reachable):
        kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo &
        kubectl port-forward svc/cenotoo-kafka-kafka-bootstrap 9092:9092 -n cenotoo &
        kubectl port-forward svc/cenotoo-api 8000:8000 -n cenotoo &

    REST credentials (if running full auth stack):
        CENOTOO_API_URL, CENOTOO_USER, CENOTOO_PASS  OR  CENOTOO_API_KEY

Run:
    python examples/mqtt/06_roundtrip.py
    python examples/mqtt/06_roundtrip.py --skip-rest   # Kafka only
    python examples/mqtt/06_roundtrip.py --skip-kafka  # REST only
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import uuid

import paho.mqtt.client as mqtt
import requests
from confluent_kafka import Consumer, KafkaError

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_USERNAME = os.getenv("KAFKA_USERNAME", "")
KAFKA_PASSWORD = os.getenv("KAFKA_PASSWORD", "")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "PLAIN")

API_URL = os.getenv("CENOTOO_API_URL", "http://localhost:8000")
API_USER = os.getenv("CENOTOO_USER", "")
API_PASS = os.getenv("CENOTOO_PASS", "")
API_KEY = os.getenv("CENOTOO_API_KEY", "")

ORG = os.getenv("ORG", "myorg")
PROJECT_NAME = os.getenv("PROJECT", "myproject")
COLLECTION = os.getenv("COLLECTION", "sensors")

MQTT_TOPIC = f"{ORG}/{PROJECT_NAME}/{COLLECTION}"
KAFKA_TOPIC = f"{ORG}.{PROJECT_NAME}.{COLLECTION}"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def mqtt_publish(payload: dict, timeout: float = 5.0) -> bool:
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"roundtrip-pub-{uuid.uuid4().hex[:6]}",
    )
    username = os.getenv("MQTT_USERNAME", "")
    password = os.getenv("MQTT_PASSWORD", "")
    if username and password:
        client.username_pw_set(username, password)

    done = threading.Event()
    result_holder: dict = {"ok": False}

    def on_connect(cli, userdata, flags, rc, properties=None):
        if rc != 0:
            print(f"[MQTT] Connect failed rc={rc}")
            done.set()

    def on_publish(cli, userdata, mid, reason_code=None, properties=None):
        result_holder["ok"] = True
        done.set()

    client.on_connect = on_connect
    client.on_publish = on_publish

    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()
    time.sleep(0.6)

    msg = client.publish(MQTT_TOPIC, json.dumps(payload), qos=1)
    # Wait for PUBACK or timeout
    done.wait(timeout)
    client.loop_stop()
    client.disconnect()
    return result_holder["ok"] and msg.is_published()


def kafka_wait_for_marker(marker: str, timeout: float = 15.0) -> dict | None:
    """Subscribe from 'latest' and wait until an envelope with marker appears."""
    group_id = f"roundtrip-verify-{uuid.uuid4().hex[:6]}"
    cfg: dict = {
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": group_id,
        "auto.offset.reset": "latest",
        "enable.auto.commit": True,
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

    consumer = Consumer(cfg)
    consumer.subscribe([KAFKA_TOPIC])
    print(f"[KAFKA] Listening on {KAFKA_TOPIC} (group {group_id}) for marker={marker!r} ...")

    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() in (
                    KafkaError._PARTITION_EOF,
                    KafkaError.UNKNOWN_TOPIC_OR_PART,
                ):
                    continue
                print(f"[KAFKA] Error: {msg.error()}")
                continue
            try:
                env = json.loads(msg.value().decode("utf-8"))
            except Exception:
                continue
            payload = env.get("payload", {})
            if isinstance(payload, dict) and payload.get("_roundtrip_marker") == marker:
                print(f"[KAFKA] ✓ Found matching envelope at offset {msg.offset()}")
                return env
    finally:
        consumer.close()
    return None


def rest_login() -> str | None:
    if not API_USER or not API_PASS:
        return None
    try:
        resp = requests.post(
            f"{API_URL}/token",
            data={"username": API_USER, "password": API_PASS},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["access_token"]
    except Exception as exc:
        print(f"[REST] Login failed: {exc}")
        return None


def rest_verify_via_get_data(marker: str, timeout: float = 20.0) -> bool:
    """Poll GET /get_data until the marker appears (Cassandra eventual delay)."""
    if not API_URL:
        print("[REST] CENOTOO_API_URL not set — skipping REST verification")
        return False

    # Resolve auth header
    headers: dict = {}
    token = rest_login()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    elif API_KEY:
        headers["X-API-Key"] = API_KEY
    else:
        print("[REST] No credentials (CENOTOO_USER/PASS or CENOTOO_API_KEY) — skipping REST check")
        print("       To verify via REST, set them and ensure project/collection exist.")
        return False

    # Resolve project + collection IDs
    try:
        # Find project
        resp = requests.get(f"{API_URL}/projects", headers=headers, timeout=10)
        resp.raise_for_status()
        projects = resp.json()
        project = next(
            (
                p
                for p in projects
                if p.get("project_name") == PROJECT_NAME or p.get("name") == PROJECT_NAME
            ),
            None,
        )
        if not project:
            print(f"[REST] Project '{PROJECT_NAME}' not found — skipping REST check")
            return False
        pid = project["id"]

        # Find collection
        resp = requests.get(f"{API_URL}/projects/{pid}/collections", headers=headers, timeout=10)
        resp.raise_for_status()
        collections = (
            resp.json() if isinstance(resp.json(), list) else resp.json().get("collections", [])
        )
        # collections may be list of dicts
        coll = next(
            (
                c
                for c in collections
                if c.get("name") == COLLECTION or c.get("collection_name") == COLLECTION
            ),
            None,
        )
        if not coll:
            print(
                f"[REST] Collection '{COLLECTION}' not found in project {pid} — skipping REST check"
            )
            return False
        cid = coll.get("id") or coll.get("collection_id") or coll.get("name")

        print(
            f"[REST] Polling GET /projects/{pid}/collections/{cid}/get_data for marker={marker!r} ..."
        )
        deadline = time.time() + timeout
        while time.time() < deadline:
            resp = requests.get(
                f"{API_URL}/projects/{pid}/collections/{cid}/get_data",
                headers=headers,
                params={"limit": 20, "order": "desc"},
                timeout=10,
            )
            if resp.status_code != 200:
                print(f"[REST] get_data returned {resp.status_code}: {resp.text[:300]}")
                time.sleep(2)
                continue
            body = resp.json()
            rows = body if isinstance(body, list) else body.get("data", body.get("rows", []))
            for row in rows:
                # Cassandra flattens payload fields as top-level columns + envelope metadata
                if (
                    row.get("_roundtrip_marker") == marker
                    or row.get("payload", {}).get("_roundtrip_marker") == marker
                ):
                    print(f"[REST] ✓ Found row via get_data: {json.dumps(row, indent=2)[:800]}")
                    return True
            time.sleep(2)

        print(f"[REST] ✗ Marker not found after {timeout}s — data may still be propagating")
        return False

    except Exception as exc:
        print(f"[REST] Verification error: {exc}")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="MQTT round-trip verification")
    parser.add_argument("--skip-kafka", action="store_true", help="Skip Kafka verification")
    parser.add_argument("--skip-rest", action="store_true", help="Skip REST/Cassandra verification")
    parser.add_argument(
        "--timeout", type=float, default=20, help="Seconds to wait for verification"
    )
    args = parser.parse_args()

    marker = f"roundtrip-{uuid.uuid4().hex[:8]}"
    payload = {
        "sensor_id": "roundtrip-tester",
        "_roundtrip_marker": marker,
        "temperature": 23.7,
        "humidity": 55,
        "ts": int(time.time() * 1000),
        "note": "06_roundtrip.py verification message — safe to delete",
    }

    print("=" * 70)
    print(" Cenotoo MQTT Round-trip Test")
    print("=" * 70)
    print(f" MQTT topic:  {MQTT_TOPIC}")
    print(f" Kafka topic: {KAFKA_TOPIC}")
    print(f" Marker:      {marker}")
    print(f" Payload:     {json.dumps(payload)}")
    print("-" * 70)

    # For Kafka verification we must subscribe BEFORE publishing (latest offset)
    kafka_thread_result: dict = {"envelope": None}
    kafka_thread = None
    if not args.skip_kafka:

        def _kafka_wait():
            kafka_thread_result["envelope"] = kafka_wait_for_marker(marker, timeout=args.timeout)

        kafka_thread = threading.Thread(target=_kafka_wait, daemon=True)
        kafka_thread.start()
        time.sleep(2)  # let consumer join group

    # Publish
    print(f"[MQTT] Publishing to {MQTT_TOPIC} ...")
    ok = mqtt_publish(payload)
    if not ok:
        print("[MQTT] ✗ Publish failed or not acknowledged")
        sys.exit(1)
    print("[MQTT] ✓ Publish acknowledged")

    # Wait for Kafka
    kafka_ok = None
    if kafka_thread is not None:
        kafka_thread.join(timeout=args.timeout + 5)
        env = kafka_thread_result["envelope"]
        if env:
            print(
                f"[KAFKA] ✓ Verified — envelope payload: {json.dumps(env.get('payload'), indent=2)}"
            )
            kafka_ok = True
        else:
            print(f"[KAFKA] ✗ Not seen on Kafka within {args.timeout}s")
            kafka_ok = False

    # Verify via REST (polls Cassandra)
    rest_ok = None
    if not args.skip_rest:
        # Small delay — Cassandra writer is async
        print("[REST] Waiting 2s for Cassandra writer ...")
        time.sleep(2)
        rest_ok = rest_verify_via_get_data(marker, timeout=args.timeout)

    # Summary
    print("=" * 70)
    print(" Summary:")
    print(f"   Publish: {'✓' if ok else '✗'}")
    if kafka_ok is not None:
        print(f"   Kafka:   {'✓' if kafka_ok else '✗'}")
    if rest_ok is not None:
        print(f"   REST/Cassandra: {'✓' if rest_ok else '✗'}")
    print("=" * 70)

    if ok and (kafka_ok is not False) and (rest_ok is not False):
        print(" Round-trip OK — MQTT ingestion pipeline is healthy.")
    else:
        print(" Round-trip had failures — check logs above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
