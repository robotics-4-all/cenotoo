#!/usr/bin/env python3
"""
07 — Device Emulator (realistic fleet simulation)

Simulates one or more physical devices that:
  - Connect to Mosquitto over MQTT (with optional auth)
  - Publish periodic telemetry (temperature, humidity, battery, GPS)
  - Handle disconnects / reconnects gracefully (paho auto-reconnect)
  - Optionally listen for shadow / command messages on a downlink topic
  - Support clean shutdown via SIGINT/SIGTERM

This is a good starting point for building your own firmware bridge
or edge gateway — replace make_telemetry() with real sensor reads.

Downlink / device shadow (optional):
    Cenotoo exposes a device shadow at:
        PUT /projects/{pid}/devices/{did}/shadow/desired
        GET /projects/{pid}/devices/{did}/shadow
    A separate MQTT downlink topic is NOT part of the default stack, but
    you can easily add one by:
      - Having the device subscribe to  \"{org}/{project}/commands/{device_id}\"
      - Having your backend publish commands there (needs bridge superuser
        or a custom ACL rule).

Run:
    # Single device, every 5 seconds:
    python examples/mqtt/07_device_emulator.py --device-id edge-001 --interval 5

    # Fleet of 5 devices:
    python examples/mqtt/07_device_emulator.py --fleet 5 --interval 3

    # With auth:
    MQTT_USERNAME=<project-uuid> MQTT_PASSWORD=<api-key> \\
    python examples/mqtt/07_device_emulator.py --device-id edge-001

    # With downlink listener:
    python examples/mqtt/07_device_emulator.py --device-id edge-001 --listen-commands
"""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import threading
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
    print(f"\n[EMULATOR] Signal {signum} — stopping ...")
    _stop = True


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


# ---------------------------------------------------------------------------
# Telemetry generator — replace with real sensor I/O
# ---------------------------------------------------------------------------
def make_telemetry(device_id: str, seq: int) -> dict:
    """Simulate a sensor reading. Replace body with actual hardware reads."""
    # Simulate slow drift + noise
    base_temp = 22.0 + 2 * random.random()
    return {
        "device_id": device_id,
        "seq": seq,
        "temperature": round(base_temp + random.uniform(-0.8, 0.8), 2),
        "humidity": round(55 + random.uniform(-8, 8), 1),
        "pressure": round(1013 + random.uniform(-5, 5), 1),
        "battery_v": round(3.85 - seq * 0.0001 + random.uniform(-0.05, 0.05), 3),
        "rssi": random.randint(-78, -42),
        "location": {
            "lat": round(37.98 + random.uniform(-0.002, 0.002), 5),
            "lon": round(23.73 + random.uniform(-0.002, 0.002), 5),
        },
        "ts": int(time.time() * 1000),
    }


# ---------------------------------------------------------------------------
# Single device emulator
# ---------------------------------------------------------------------------
class DeviceEmulator:
    def __init__(self, device_id: str, topic: str, interval: float, listen_commands: bool):
        self.device_id = device_id
        self.topic = topic
        self.interval = interval
        self.listen_commands = listen_commands
        self.seq = 0
        self.published = 0
        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"emu-{device_id}-{uuid.uuid4().hex[:4]}",
        )
        username = os.getenv("MQTT_USERNAME", "")
        password = os.getenv("MQTT_PASSWORD", "")
        if username and password:
            self.client.username_pw_set(username, password)

        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)

        # Downlink topic for this device (convention — not enforced by Cenotoo)
        self.cmd_topic = f"{ORG}/{PROJECT}/commands/{device_id}"

    def _on_connect(self, cli, userdata, flags, reason_code, properties=None):
        if reason_code == 0:
            print(f"[{self.device_id}] Connected to {MQTT_HOST}:{MQTT_PORT}")
            if self.listen_commands:
                cli.subscribe(self.cmd_topic, qos=1)
                print(f"[{self.device_id}] Listening for commands on '{self.cmd_topic}'")
        else:
            print(f"[{self.device_id}] Connect failed rc={reason_code}")

    def _on_disconnect(self, cli, userdata, flags, reason_code, properties=None):
        if reason_code != 0:
            print(f"[{self.device_id}] Unexpected disconnect rc={reason_code}")

    def _on_message(self, cli, userdata, msg):
        try:
            cmd = json.loads(msg.payload.decode("utf-8"))
        except Exception:
            cmd = msg.payload.decode("utf-8", errors="replace")
        print(f"[{self.device_id}] ← Command on {msg.topic}: {cmd}")
        # Example: handle a 'reboot' or 'set_interval' command
        if isinstance(cmd, dict) and "set_interval" in cmd:
            try:
                new_interval = float(cmd["set_interval"])
                self.interval = max(0.5, new_interval)
                print(f"[{self.device_id}] Interval updated to {self.interval}s")
            except (ValueError, TypeError):
                pass

    def start(self):
        self.client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
        self.client.loop_start()
        time.sleep(0.5)

    def stop(self):
        self.client.loop_stop()
        self.client.disconnect()

    def publish_once(self):
        self.seq += 1
        payload = make_telemetry(self.device_id, self.seq)
        result = self.client.publish(self.topic, json.dumps(payload), qos=1)
        # Don't block on wait_for_publish — keep cadence
        self.published += 1
        print(
            f"[{self.device_id}] → seq={self.seq:4d}  "
            f"temp={payload['temperature']:5.1f}°C  hum={payload['humidity']:4.1f}%  "
            f"bat={payload['battery_v']:.2f}V  rssi={payload['rssi']}dBm"
        )
        return result

    def run_loop(self):
        self.start()
        print(
            f"[{self.device_id}] Publishing to '{self.topic}' every {self.interval}s — Ctrl+C to stop"
        )
        try:
            while not _stop:
                self.publish_once()
                # Sleep in small increments so SIGINT is responsive
                slept = 0
                while slept < self.interval and not _stop:
                    time.sleep(min(0.2, self.interval - slept))
                    slept += 0.2
        finally:
            self.stop()
            print(f"[{self.device_id}] Stopped — published {self.published} message(s)")


# ---------------------------------------------------------------------------
# Main — single or fleet mode
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="MQTT device emulator")
    parser.add_argument("--device-id", default="edge-001", help="Device identifier")
    parser.add_argument(
        "--fleet",
        type=int,
        default=0,
        help="Fleet size — spawn N emulators (overrides --device-id)",
    )
    parser.add_argument("--interval", type=float, default=5.0, help="Seconds between publishes")
    parser.add_argument("--topic", default=None, help="Override MQTT topic")
    parser.add_argument(
        "--listen-commands", action="store_true", help="Subscribe to downlink command topic"
    )
    args = parser.parse_args()

    topic = args.topic or f"{ORG}/{PROJECT}/{COLLECTION}"

    if args.fleet and args.fleet > 1:
        print(f"[FLEET] Starting {args.fleet} device(s) → topic '{topic}' every {args.interval}s")
        emulators = [
            DeviceEmulator(f"edge-{i:03d}", topic, args.interval, args.listen_commands)
            for i in range(1, args.fleet + 1)
        ]
        threads = []
        for emu in emulators:
            t = threading.Thread(target=emu.run_loop, daemon=True)
            t.start()
            threads.append(t)
            time.sleep(0.15)  # stagger connects

        try:
            while not _stop:
                time.sleep(0.5)
        finally:
            # Give threads a moment to stop
            time.sleep(0.5)
            total = sum(e.published for e in emulators)
            print(f"[FLEET] Total published: {total} message(s) across {args.fleet} device(s)")
    else:
        emu = DeviceEmulator(args.device_id, topic, args.interval, args.listen_commands)
        emu.run_loop()


if __name__ == "__main__":
    main()
