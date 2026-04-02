<p align="center">
  <img src=".github/assets/cenotoo_landing.png" alt="Cenotoo" width="100%" />
</p>

<h1 align="center">Cenotoo</h1>

<p align="center">
  <strong>The open data backbone for IoT and cyber-physical systems.</strong><br/>
  Ingest from MQTT or HTTP · Stream through Kafka · Persist in Cassandra · Query via REST
</p>

<p align="center">
  <a href="#-quick-start">
    <img src="https://img.shields.io/badge/get_started-blue?style=for-the-badge" alt="Get Started" />
  </a>
  <a href="docs/k3s-setup.md">
    <img src="https://img.shields.io/badge/deployment_guide-teal?style=for-the-badge" alt="Deployment Guide" />
  </a>
  <a href="https://github.com/robotics-4-all/cenotoo-api">
    <img src="https://img.shields.io/badge/REST_API-gray?style=for-the-badge" alt="REST API" />
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Kafka-KRaft_(no_ZooKeeper)-blue?logo=apachekafka&logoColor=white" alt="Kafka KRaft" />
  <img src="https://img.shields.io/badge/Cassandra-4.x-1287B1?logo=apachecassandra&logoColor=white" alt="Cassandra" />
  <img src="https://img.shields.io/badge/Flink-1.18-E6526F?logo=apacheflink&logoColor=white" alt="Flink" />
  <img src="https://img.shields.io/badge/FastAPI-REST_API-009688?logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/MQTT-Mosquitto-660066?logo=eclipsemosquitto&logoColor=white" alt="Mosquitto" />
  <img src="https://img.shields.io/badge/Kubernetes-k3s-326CE5?logo=kubernetes&logoColor=white" alt="Kubernetes" />
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker Compose" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-Apache_2.0-orange?logo=apache&logoColor=white" alt="Apache 2.0" />
  </a>
</p>

---

## What is Cenotoo?

Cenotoo is a **production-ready Big Data Management System (BDMS)** purpose-built for IoT and cyber-physical systems. It packages Apache Kafka, Cassandra, and Flink into a single opinionated platform — with an MQTT bridge, a REST API, real-time SSE streaming, and a device shadow system on top.

Connect physical devices via MQTT or HTTP. Route data through Kafka. Process it with Flink. Persist it in Cassandra. Query or stream it through a REST API. **Deploy locally in 2 minutes or to production Kubernetes in 10.**

---

## Provided Functionality

| # | Feature | Status |
|---|---------|:------:|
| 1 | **HTTP Data Ingestion** — single records or batches via `POST /send_data`, schema-validated | ✅ |
| 2 | **MQTT Device Ingestion** — Mosquitto broker + bridge auto-routes any MQTT topic to Kafka | ✅ |
| 3 | **Historical Data Query** — `GET /get_data` with field filters, time range, ordering, and pagination | ✅ |
| 4 | **Time-series Statistics** — `avg`, `max`, `min`, `sum`, `count`, `distinct` over configurable intervals | ✅ |
| 5 | **SSE Real-time Streaming** — `GET /stream` delivers live Kafka messages as Server-Sent Events | ✅ |
| 6 | **Device Registry** — `POST/GET/PUT/DELETE /devices` per project | ✅ |
| 7 | **Device Shadow / Twin** — separate `desired` and `reported` state per device; automatic `delta` computation | ✅ |
| 8 | **Schema Evolution** — `PATCH /schema` adds or removes Cassandra columns with zero downtime | ✅ |
| 9 | **JWT + API Key Auth** — bearer tokens for users; scoped keys (`read`/`write`/`master`) for devices and services | ✅ |
| 10 | **Stream Processing** — Apache Flink 1.18, Kafka source table, exactly-once semantics | ✅ |
| 11 | **Observability** — Prometheus metrics, Grafana dashboards, alerting rules — deployed in one script | ✅ |
| 12 | **Rate Limiting** — configurable per-endpoint limits via `slowapi` | ✅ |
| 13 | **OpenTelemetry Tracing** — opt-in distributed tracing via `OTLP_ENDPOINT` | ✅ |
| 14 | **End-to-end Security** — SCRAM-SHA-512 on Kafka, `PasswordAuthenticator` on Cassandra | ✅ |
| 15 | **Dual Deployment** — same stack, same config: Docker Compose (dev) or Kubernetes (prod) | ✅ |

---

## Architecture

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                     Cenotoo Platform                        │
                    │                                                             │
  MQTT Devices ───► │  Mosquitto ──► MQTT Bridge ──────────────────┐             │
                    │                                               ▼             │
  HTTP Clients ───► │  REST API (FastAPI) ──────────────►  Kafka (KRaft)          │
                    │  ├─ POST /send_data                    │         │          │
                    │  ├─ GET  /get_data                     ▼         ▼          │
                    │  ├─ GET  /stream (SSE) ◄──┐        Flink    Consumer        │
                    │  ├─ GET  /statistics      │        (SQL)     Bridge         │
                    │  ├─ CRUD /devices         │          │         │            │
                    │  ├─ GET  /shadow          │          └────┬────┘            │
                    │  └─ PATCH /schema         │               ▼                 │
                    │                           └────────  Cassandra              │
                    │                                                             │
                    │  ┌──────────────────────────────────────────────────────┐  │
                    │  │         Prometheus  ·  Grafana  ·  Alert Rules       │  │
                    │  └──────────────────────────────────────────────────────┘  │
                    └─────────────────────────────────────────────────────────────┘
```

| | Docker Compose | Kubernetes (k3s) |
|---|---|---|
| **Best for** | Local development and testing | Staging and production |
| **Kafka** | 2 brokers, KRaft — no ZooKeeper | Strimzi operator + KafkaNodePools |
| **Cassandra** | 2 nodes, local volumes | StatefulSet + persistent storage |
| **Flink** | Single JobManager | Operator-managed, K8s-native HA |
| **MQTT** | Mosquitto + bridge container | Deployment + bridge container |
| **Monitoring** | — | kube-prometheus-stack |
| **Setup time** | ~2 minutes | ~10 minutes |

---

## 🚀 Quick Start

### Option A — Docker Compose (2 minutes)

```bash
# 1. Configure
cp .env.example .env
python scripts/generate-cluster-id.py   # copy output into .env as KAFKA_CLUSTER_ID

# 2. Build images and launch
bash scripts/build-images.sh
docker-compose up -d kafka1 cassandra1 jobmanager taskmanager   # node 1
docker-compose up -d kafka2 cassandra2                          # node 2 (optional)

# 3. Initialize Cassandra schema
pip install -r requirements.txt
python cassandra/create_cassandra_tables.py

# 4. Verify — all containers should show (healthy)
docker ps
```

### Option B — Kubernetes / k3s (10 minutes)

Each script is **idempotent** — safe to re-run and picks up where it left off:

```bash
sudo ./scripts/01-install-k3s.sh                # k3s + Helm
sudo ./scripts/02-install-cert-manager.sh       # TLS (K8ssandra prerequisite)
sudo ./scripts/03-install-strimzi-operator.sh   # Kafka operator
sudo ./scripts/04-install-k8ssandra-operator.sh # Cassandra operator
sudo ./scripts/05-install-flink-operator.sh     # Flink operator
sudo ./scripts/06-install-monitoring.sh         # Prometheus + Grafana (optional)
sudo ./scripts/07-deploy-cenotoo.sh             # Deploy the platform
./scripts/08-deploy-api.sh                      # Build + deploy the REST API
```

**Verify:**

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://${NODE_IP}:30080/health   # → {"status":"ok"}
curl http://${NODE_IP}:30080/docs     # Swagger UI
```

For the full walkthrough, see the **[Deployment Guide](docs/k3s-setup.md)**.

---

## REST API

The [cenotoo-api](https://github.com/robotics-4-all/cenotoo-api) repository provides the full REST interface. After deployment, Swagger UI is available at `http://<node-ip>:30080/docs`.

### Core Workflow

```bash
BASE="http://<node-ip>:30080/api/v1"

# Authenticate
TOKEN=$(curl -s -X POST "$BASE/token" \
  -d "username=admin&password=<pass>" | jq -r .access_token)

# Create a project and collection
PROJECT=$(curl -s -X POST "$BASE/projects" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"smart_building","description":"","tags":[]}' \
  | jq -r '.id.project_id')

curl -s -X POST "$BASE/projects/$PROJECT/collections" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"sensors","tags":[],"collection_schema":{"temp":"float","room":"text"}}'

# Generate a scoped write key for devices
WRITE_KEY=$(curl -s -X POST "$BASE/projects/$PROJECT/keys" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"key_type":"write"}' | jq -r .api_key)

# Ingest a reading
curl -X POST "$BASE/projects/$PROJECT/collections/<cid>/send_data" \
  -H "X-API-Key: $WRITE_KEY" -H "Content-Type: application/json" \
  -d '{"temp": 22.5, "room": "lab-01"}'

# Stream live data
curl -N "$BASE/projects/$PROJECT/collections/<cid>/stream" -H "X-API-Key: $WRITE_KEY"
```

### Endpoint Reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/projects/{pid}/collections/{cid}/send_data` | `POST` | Ingest single or batch records |
| `/projects/{pid}/collections/{cid}/get_data` | `GET` | Query with filters, pagination, time range |
| `/projects/{pid}/collections/{cid}/statistics` | `GET` | Aggregated stats over time intervals |
| `/projects/{pid}/collections/{cid}/stream` | `GET` | Live SSE stream directly from Kafka |
| `/projects/{pid}/collections/{cid}/schema` | `PATCH` | Add or remove schema fields, zero downtime |
| `/projects/{pid}/devices` | `POST/GET` | Register and list devices |
| `/projects/{pid}/devices/{did}` | `GET/PUT/DELETE` | Device CRUD |
| `/projects/{pid}/devices/{did}/shadow` | `GET` | Full shadow: `desired`, `reported`, `delta` |
| `/projects/{pid}/devices/{did}/shadow/desired` | `PUT` | Set desired state (cloud → device) |
| `/projects/{pid}/devices/{did}/shadow/reported` | `PUT` | Update reported state (device → cloud) |

---

## MQTT Ingestion

Any MQTT-capable device can start publishing with zero integration code:

```bash
# Publish from any client — the bridge routes it to Kafka automatically
mosquitto_pub -h <broker-ip> -p 1883 \
  -t "myorg/myproject/sensors" \
  -m '{"temp": 22.5, "humidity": 58, "node": "roof-01"}'
```

The MQTT bridge subscribes to `#`, wraps each payload in a canonical JSON envelope, and produces to the Kafka topic `{org}.{project}.{collection}`. From there the Consumer Bridge writes to Cassandra and the SSE endpoint streams to subscribers — automatically.

---

## Integration Tests

All three high-level feature suites run against a live cluster:

```bash
export CENOTOO_ADMIN_PASSWORD=<your-password>

bash scripts/14-test-sse-stream.sh        # 12 SSE streaming tests
bash scripts/15-test-device-management.sh # 24 device registry + shadow tests
bash scripts/16-test-schema-evolution.sh  # 21 schema evolution tests
```

Unit tests (no infrastructure required):

```bash
pytest tests/ -v
```

---

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KAFKA_BROKER1_IP` | Kafka broker 1 address | — |
| `KAFKA_BROKER2_IP` | Kafka broker 2 address | — |
| `KAFKA_CLUSTER_ID` | KRaft cluster ID — generate once with `scripts/generate-cluster-id.py` | — |
| `KAFKA_USERNAME` | SASL username | `admin` |
| `KAFKA_PASSWORD` | SASL password | — |
| `CASSANDRA_SEEDS` | Cassandra contact points | — |
| `CASSANDRA_DC` | Datacenter name | `datacenter1` |
| `CASSANDRA_RF` | Replication factor | `2` |

### Naming Conventions

| Thing | Pattern | Example |
|-------|---------|---------|
| Kafka topic | `{org}.{project}.{collection}` | `acme.iot.sensors` |
| Cassandra keyspace | `{org}` | `acme` |
| Cassandra table | `{project}_{collection}` | `iot_sensors` |
| Consumer group | `{topic}_cassandra_writer` | `acme.iot.sensors_cassandra_writer` |

---

## Tech Stack

| Component | Technology | Notes |
|-----------|------------|-------|
| Message Streaming | Apache Kafka (KRaft) | No ZooKeeper |
| Stream Processing | Apache Flink 1.18 | Stateful, exactly-once |
| Persistence | Apache Cassandra 4.x | Horizontally scalable |
| REST API | FastAPI + Pydantic | Swagger UI included |
| MQTT Broker | Eclipse Mosquitto | Bridge → Kafka |
| Container Orchestration | Kubernetes (k3s) | Lightweight, production-ready |
| Kafka Operator | Strimzi 0.45+ | CRD-driven, full KRaft support |
| Cassandra Operator | K8ssandra | Medusa backup, TLS |
| Flink Operator | Apache Flink K8s Operator 1.10+ | K8s-native HA |
| Monitoring | Prometheus + Grafana | kube-prometheus-stack |
| CI/CD | GitHub Actions | Lint → typecheck → test |

---

## Contributing

Contributions, issues, and feature requests are welcome. Please check [open issues](../../issues) before opening a new one.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
