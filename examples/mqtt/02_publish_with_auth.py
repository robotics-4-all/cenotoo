#!/usr/bin/env python3
"""
02 — Authenticated Publish (production / go-auth)

When the Mosquitto go-auth plugin is enabled (default in production k8s),
every MQTT publish is authenticated and authorised against the Cenotoo
metadata DB (PostgreSQL).

Authentication:
    username = <project_id>   (UUID returned by POST /projects)
    password = <api_key>      (write or master scope, from POST /projects/{id}/keys)

Authorisation (ACL):
    The topic MUST be  \"{org}/{project}/{collection}\" where:
      - {org}     matches the organization_name for ORGANIZATION_ID
      - {project} matches the project_name for the given project_id
    Any other topic is rejected (ACL deny → publish silently dropped).

This example shows how to obtain credentials via the REST API and then
publish with them — plus how to handle auth errors gracefully.

Prerequisites:
    pip install -r requirements.txt requests

    You need a running Cenotoo API:
        kubectl port-forward svc/cenotoo-api 8000:8000 -n cenotoo  (or use ingress)
    And the MQTT broker:
        kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo

Workflow:
    1. Login  → POST /token  (get JWT)
    2. Create / fetch project
    3. Create API key (write scope)
    4. Publish to MQTT using project_id + api_key as credentials

Run:
    CENOTOO_API_URL=http://localhost:8000 \\
    CENOTOO_USER=admin CENOTOO_PASS=changeme \\
    python examples/mqtt/02_publish_with_auth.py

    # Or skip API provisioning and publish directly if you already have keys:
    MQTT_USERNAME=<project-uuid> MQTT_PASSWORD=<api-key> \\
    python examples/mqtt/02_publish_with_auth.py --direct
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid

import paho.mqtt.client as mqtt
import requests

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
API_URL = os.getenv("CENOTOO_API_URL", "http://localhost:8000")
API_USER = os.getenv("CENOTOO_USER", "admin")
API_PASS = os.getenv("CENOTOO_PASS", "changeme")
MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))

ORG = os.getenv("ORG", "myorg")
PROJECT_NAME = os.getenv("PROJECT", "myproject")
COLLECTION = os.getenv("COLLECTION", "sensors")


# ---------------------------------------------------------------------------
# REST helpers — provision project + api key
# ---------------------------------------------------------------------------
def api_login(api_url: str, username: str, password: str) -> str:
    resp = requests.post(
        f"{api_url}/token",
        data={"username": username, "password": password},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def ensure_project(api_url: str, token: str, project_name: str) -> str:
    headers = {"Authorization": f"Bearer {token}"}
    # Try to find existing project
    resp = requests.get(f"{api_url}/projects", headers=headers, timeout=10)
    resp.raise_for_status()
    for p in resp.json():
        if p.get("project_name") == project_name or p.get("name") == project_name:
            print(f"[API] Found existing project '{project_name}'  id={p['id']}")
            return p["id"]
    # Create new one
    resp = requests.post(
        f"{api_url}/projects",
        headers=headers,
        json={"project_name": project_name},
        timeout=10,
    )
    resp.raise_for_status()
    pid = resp.json()["id"]
    print(f"[API] Created project '{project_name}'  id={pid}")
    return pid


def create_api_key(api_url: str, token: str, project_id: str) -> str:
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.post(
        f"{api_url}/projects/{project_id}/keys",
        headers=headers,
        json={"scope": "write", "name": "mqtt-example-key"},
        timeout=10,
    )
    resp.raise_for_status()
    key = resp.json().get("api_key") or resp.json().get("key") or resp.json().get("value")
    if not key:
        # Some deployments return the key under different field — dump for debugging
        print(f"[API] Key response: {resp.json()}")
        raise RuntimeError("Could not extract api_key from response")
    print(f"[API] Created write-scoped API key: {key[:8]}…")
    return key


# ---------------------------------------------------------------------------
# MQTT publish with given credentials
# ---------------------------------------------------------------------------
def mqtt_publish(username: str, password: str, topic: str, payload: dict) -> None:
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"cenotoo-auth-example-{uuid.uuid4().hex[:6]}",
    )

    connected = {"ok": False, "rc": None}
    published = {"mid": None, "done": False}

    def on_connect(cli, userdata, flags, reason_code, properties=None):
        connected["rc"] = reason_code
        if reason_code == 0:
            connected["ok"] = True
            print(f"[MQTT] Authenticated as project {username}")
        else:
            print(f"[MQTT] Auth failed — reason_code={reason_code}")
            # 4 = bad username/password, 5 = not authorised
            if reason_code == 4:
                print(
                    "       → Check that username is the project UUID and password is the API key."
                )
            elif reason_code == 5:
                print(
                    "       → Check topic matches {org}/{project}/{collection} for this project/org."
                )

    def on_publish(cli, userdata, mid, reason_code=None, properties=None):
        published["mid"] = mid
        published["done"] = True
        print(f"[MQTT] Publish acknowledged (mid={mid})")

    def on_disconnect(cli, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            print(f"[MQTT] Disconnect reason_code={reason_code}")

    client.on_connect = on_connect
    client.on_publish = on_publish
    client.on_disconnect = on_disconnect
    client.username_pw_set(username, password)

    print(f"[MQTT] Connecting to {MQTT_HOST}:{MQTT_PORT} as {username} ...")
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()

    # Wait for CONNACK (up to 5s)
    for _ in range(50):
        if connected["rc"] is not None:
            break
        time.sleep(0.1)

    if not connected["ok"]:
        client.loop_stop()
        print("[MQTT] ✗ Could not connect — aborting publish")
        sys.exit(1)

    payload_str = json.dumps(payload)
    print(f"[MQTT] Publishing to '{topic}': {payload_str}")
    result = client.publish(topic, payload_str, qos=1)
    result.wait_for_publish(timeout=5)

    if result.is_published():
        print("[MQTT] ✓ Publish succeeded (ACL passed)")
    else:
        print("[MQTT] ✗ Publish not acknowledged — likely ACL denied.")
        print("       Topic must be {org}/{project}/{collection} matching your org/project.")

    time.sleep(0.5)
    client.loop_stop()
    client.disconnect()


def main() -> None:
    parser = argparse.ArgumentParser(description="Authenticated MQTT publish example")
    parser.add_argument(
        "--direct",
        action="store_true",
        help="Skip API provisioning, use MQTT_USERNAME/PASSWORD env vars directly",
    )
    parser.add_argument(
        "--topic", default=None, help="Override MQTT topic (default: {org}/{project}/{collection})"
    )
    args = parser.parse_args()

    if args.direct:
        username = os.getenv("MQTT_USERNAME", "")
        password = os.getenv("MQTT_PASSWORD", "")
        if not username or not password:
            print(
                "ERROR: --direct requires MQTT_USERNAME (project_id) and MQTT_PASSWORD (api_key) env vars",
                file=sys.stderr,
            )
            sys.exit(2)
        project_id = username
        api_key = password
        print(f"[MODE] Direct — using credentials from env  user={project_id}")
    else:
        print(f"[API] Logging in to {API_URL} as {API_USER} ...")
        try:
            token = api_login(API_URL, API_USER, API_PASS)
        except Exception as exc:
            print(f"[API] Login failed: {exc}", file=sys.stderr)
            print(
                "      Hint: check CENOTOO_API_URL / CENOTOO_USER / CENOTOO_PASS", file=sys.stderr
            )
            print("      Or use --direct with existing MQTT_USERNAME/PASSWORD", file=sys.stderr)
            sys.exit(1)

        project_id = ensure_project(API_URL, token, PROJECT_NAME)
        api_key = create_api_key(API_URL, token, project_id)

    topic = args.topic or f"{ORG}/{PROJECT_NAME}/{COLLECTION}"

    payload = {
        "sensor_id": "auth-demo-01",
        "temperature": 24.1,
        "humidity": 61,
        "ts": int(time.time() * 1000),
        "note": "authenticated publish example",
    }

    mqtt_publish(project_id, api_key, topic, payload)

    print()
    print("Verify ingestion:")
    print(f"  Kafka topic: {ORG}.{PROJECT_NAME}.{COLLECTION}")
    print(
        f"  REST:  GET {API_URL}/projects/{project_id}/collections/<id>/get_data  (need collection id)"
    )
    print(f"  CQL:   SELECT * FROM {ORG}.{PROJECT_NAME}_{COLLECTION} LIMIT 10;")


if __name__ == "__main__":
    main()
