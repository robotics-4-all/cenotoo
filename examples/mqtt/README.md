# Cenotoo MQTT Examples

End-to-end examples for **sending** (publish) and **receiving** (subscribe / consume) data via the Cenotoo MQTT ingestion pipeline.

```
Device ──MQTT publish──► Mosquitto ──► mqtt-bridge ──► Kafka ──► Cassandra
  │                        │                │              │          │
  │  topic:                │  subscribes    │  envelope    │  topic:  │  keyspace:
  │  myorg/myproject/      │  to #          │  {           │  myorg.  │  myorg
  │  sensors               │  validates     │   mqtt_topic,│  myproj. │  table:
  │                        │  3 segments    │   payload,   │  sensors │  myproject_sensors
  │                        │                │   ts,        │          │
  │                        │                │   client_id  │          │
  │                        │                │  }           │          │
```

**Topic convention (strict — enforced by the bridge):**

| Layer | Format | Example |
|-------|--------|---------|
| MQTT (publish) | `{org}/{project}/{collection}` | `myorg/myproject/sensors` |
| Kafka (bridged) | `{org}.{project}.{collection}` | `myorg.myproject.sensors` |
| Cassandra | keyspace `{org}`, table `{project}_{collection}` | `myorg.myproject_sensors` |

> The bridge **drops** any MQTT topic that does not have exactly three non-empty slash-separated segments.

---

## Prerequisites

```bash
pip install -r examples/mqtt/requirements.txt
# paho-mqtt==2.1.0  confluent-kafka==2.3.0  requests  python-dotenv
```

Expose services locally when running against a k3s cluster:

```bash
kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo &
kubectl port-forward svc/cenotoo-kafka-kafka-bootstrap 9092:9092 -n cenotoo &  # for 05 / 06
kubectl port-forward svc/cenotoo-api 8000:8000 -n cenotoo &                    # for 02 / 06
```

Or point `MQTT_HOST`, `KAFKA_BOOTSTRAP_SERVERS`, `CENOTOO_API_URL` at your ingress / node IP.

Copy and edit env config:

```bash
cp examples/mqtt/env.example .env
# edit ORG / PROJECT / COLLECTION to match your Cenotoo org & project
```

---

## Sending (Publish)

### `01_basic_publish.py` — minimal single publish

The simplest possible publish. No auth (works against an open / local-dev broker).

```bash
python examples/mqtt/01_basic_publish.py
MQTT_HOST=192.168.1.50 python examples/mqtt/01_basic_publish.py
```

Publishes one JSON payload to `{org}/{project}/{collection}` with `QoS 1` and waits for `PUBACK`.

### `02_publish_with_auth.py` — authenticated publish (production)

When the Mosquitto **go-auth** plugin is enabled (default in production), every publish is checked:

- **Authentication:** `username = <project_id>` (UUID), `password = <api_key>` with `write` or `master` scope.
- **Authorisation (ACL):** topic must be `{org}/{project}/{collection}` where `org` and `project` match the names in Postgres for that `project_id`. Publish-only (`acc == 2`); subscribe is denied for regular keys.

The script can **provision** credentials via the REST API automatically:

```bash
# Full provisioning flow: login → find/create project → create write key → publish
CENOTOO_API_URL=http://localhost:8000 CENOTOO_USER=admin CENOTOO_PASS=changeme \
python examples/mqtt/02_publish_with_auth.py

# Or use existing credentials directly:
MQTT_USERNAME=<project-uuid> MQTT_PASSWORD=<api-key> \
python examples/mqtt/02_publish_with_auth.py --direct

# Wrong topic (ACL deny demo):
MQTT_USERNAME=<uuid> MQTT_PASSWORD=<key> \
python examples/mqtt/02_publish_with_auth.py --direct --topic "wrong/project/topic"
```

### `03_batch_publish.py` — high-throughput / fleet simulation

Reuses a single connection to publish many messages, rotating across simulated device IDs.

```bash
python examples/mqtt/03_batch_publish.py --count 50 --interval 0.1
python examples/mqtt/03_batch_publish.py --count 1000 --qos 0 --interval 0.01
python examples/mqtt/03_batch_publish.py --count 0 --interval 1 --devices 5   # infinite
```

### `07_device_emulator.py` — realistic device / fleet emulator

Simulates physical devices with periodic telemetry, auto-reconnect, and an optional downlink command listener.

```bash
# Single device
python examples/mqtt/07_device_emulator.py --device-id edge-001 --interval 5

# Fleet of 5 devices
python examples/mqtt/07_device_emulator.py --fleet 5 --interval 3

# With downlink listener (subscribes to {org}/{project}/commands/{device_id})
python examples/mqtt/07_device_emulator.py --device-id edge-001 --listen-commands
```

Replace `make_telemetry()` with real sensor reads for your hardware.

### `shell_examples.sh` — `mosquitto_pub` one-liners

No Python needed — pure shell:

```bash
bash examples/mqtt/shell_examples.sh
# or step through manually:
mosquitto_pub -h localhost -p 1883 -t "myorg/myproject/sensors" -m '{"temp": 22.5}' -q 1
```

Covers single publish, rich payload, non-JSON string, batch loop, and invalid-topic demo.

---

## Receiving (Subscribe / Consume)

Cenotoo has **two** receive paths. Use the one that fits your consumer:

### A) MQTT subscribe — live, broker-level (pre-bridge)

`04_subscribe.py` subscribes directly to Mosquitto and prints messages **as published** (original payload, no envelope). Useful for debugging, live dashboards, or device-to-device fan-out.

> **ACL note:** In production the go-auth plugin only allows `PUBLISH` for regular project keys (`acc == 2`). `SUBSCRIBE` is denied — the bridge superuser (`cenotoo-bridge`) is the only account that can subscribe. For backend services, prefer path B (Kafka).

```bash
# Single collection (open broker or superuser):
python examples/mqtt/04_subscribe.py --topic "myorg/myproject/sensors"

# Wildcard — all collections in a project:
python examples/mqtt/04_subscribe.py --topic "myorg/myproject/+"

# Everything (superuser only):
MQTT_USERNAME=cenotoo-bridge MQTT_PASSWORD=<bridge-pass> \
python examples/mqtt/04_subscribe.py --topic "#"

# With explicit broker:
MQTT_HOST=192.168.1.50 python examples/mqtt/04_subscribe.py --topic "myorg/#"
```

Wildcard reference: `+` = single level, `#` = multi-level (must be last).

### B) Kafka consumer — reliable, replayable (post-bridge)

`05_kafka_consumer.py` consumes from Kafka topic `myorg.myproject.sensors` and decodes the **envelope** the bridge produced. This is the recommended path for services, analytics, and anything that needs at-least-once / replay.

Envelope shape (Kafka record value = JSON bytes):

```json
{
  "mqtt_topic": "myorg/myproject/sensors",
  "payload": { "temperature": 22.5, "humidity": 58 },
  "ts": 1715000000000,
  "client_id": "cenotoo-bridge"
}
```

```bash
# Live tail (latest offset — like kafka-live-consumer):
python examples/mqtt/05_kafka_consumer.py

# Replay full history:
python examples/mqtt/05_kafka_consumer.py --from-beginning

# Specific topic / group:
python examples/mqtt/05_kafka_consumer.py --topic myorg.myproject.sensors --group my-service

# Timeout / bounded:
python examples/mqtt/05_kafka_consumer.py --max-messages 10 --timeout 30
```

Also available via the REST API without Kafka:

```bash
# Poll persisted data (Cassandra):
curl -H "X-API-Key: <read-key>" \
  "http://localhost:8000/projects/<pid>/collections/<cid>/get_data?limit=10&order=desc"

# Live SSE stream (Kafka, latest offset):
curl -H "X-API-Key: <read-key>" \
  "http://localhost:8000/projects/<pid>/collections/<cid>/stream"
```

---

## End-to-end verification

### `06_roundtrip.py` — publish → verify via Kafka + REST

Publishes a uniquely tagged message and confirms it arrived through both paths. Ideal for CI health checks and integration tests.

```bash
python examples/mqtt/06_roundtrip.py
python examples/mqtt/06_roundtrip.py --skip-rest    # Kafka only
python examples/mqtt/06_roundtrip.py --skip-kafka   # REST only
python examples/mqtt/06_roundtrip.py --timeout 30
```

Flow: subscribe to Kafka (latest) → publish via MQTT → wait for envelope with matching `_roundtrip_marker` on Kafka → poll `GET /get_data` until the row appears in Cassandra.

---

## File index

| File | Purpose | Auth | Layer |
|------|---------|------|-------|
| `01_basic_publish.py` | Minimal single publish | No | MQTT → Kafka |
| `02_publish_with_auth.py` | Provision project/key & publish with ACL | Yes (project key) | MQTT → Kafka |
| `03_batch_publish.py` | High-throughput burst / fleet loop | Optional | MQTT → Kafka |
| `04_subscribe.py` | Live subscribe with wildcards | Superuser for `#` | MQTT (pre-bridge) |
| `05_kafka_consumer.py` | Kafka envelope consumer | SASL optional | Kafka (post-bridge) |
| `06_roundtrip.py` | Publish + verify via Kafka & REST | Both | End-to-end |
| `07_device_emulator.py` | Realistic device / fleet emulator | Optional | MQTT → Kafka |
| `shell_examples.sh` | `mosquitto_pub`/`mosquitto_sub` one-liners | Optional | MQTT |
| `env.example` | Environment template | — | — |
| `requirements.txt` | Python deps | — | — |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Connection refused` | Broker not reachable | `kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo` or check `MQTT_HOST` |
| `CONNACK rc=4` (bad credentials) | Wrong `MQTT_USERNAME`/`MQTT_PASSWORD` | Username must be project UUID, password is the `write`/`master` API key |
| `CONNACK rc=5` (not authorised) | Topic does not match org/project | Topic must be `{org}/{project}/{collection}` matching Postgres names |
| Publish succeeds but no data in Kafka/Cassandra | Topic had wrong segment count | Bridge logs: `kubectl logs deploy/cenotoo-mqtt-bridge -n cenotoo` — look for `Skipping invalid MQTT topic` |
| Subscribe `rc=5` | Regular project keys cannot subscribe (ACL `acc != 2`) | Use bridge superuser or consume via Kafka (`05_kafka_consumer.py`) / REST |
| Kafka `UNKNOWN_TOPIC_OR_PART` | Topic not yet auto-created | Publish at least one message first; topic is created on first produce |
| Payload appears as hex string | Non-UTF-8 binary payload | Bridge hex-encodes undecodable bytes — send UTF-8 JSON instead |

---

## Security notes

- Change the default `cenotoo-bridge` password: edit `deploy/k8s/01-secrets/mqtt-credentials.yaml` (base64) and roll the `cenotoo-mosquitto` StatefulSet.
- Prefer `write`-scoped API keys for devices; `master` keys can also manage schema and devices.
- For TLS, expose Mosquitto on `8883` with certificates and set `MQTT_USE_TLS=true` (see commented `tls_set` blocks in the examples).
