<p align="center">
  <img src=".github/assets/cenotoo_landing.png" alt="Cenotoo" width="100%" />
</p>

<h1 align="center">Cenotoo</h1>

<p align="center">
  <strong>The open data backbone for IoT and cyber-physical systems.</strong><br/>
  Ingest from MQTT, CoAP, or HTTP &nbsp;·&nbsp; Stream through Kafka &nbsp;·&nbsp; Persist in Cassandra &nbsp;·&nbsp; Query via REST
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
  <img src="https://img.shields.io/badge/Python-3.11-3776AB?logo=python&logoColor=white" alt="Python 3.11" />
  <img src="https://img.shields.io/badge/Kafka-KRaft_(no_ZooKeeper)-blue?logo=apachekafka&logoColor=white" alt="Kafka KRaft" />
  <img src="https://img.shields.io/badge/Cassandra-4.x-1287B1?logo=apachecassandra&logoColor=white" alt="Cassandra" />
  <img src="https://img.shields.io/badge/Flink-1.18-E6526F?logo=apacheflink&logoColor=white" alt="Flink" />
  <img src="https://img.shields.io/badge/FastAPI-REST_API-009688?logo=fastapi&logoColor=white" alt="FastAPI" />
  <img src="https://img.shields.io/badge/PostgreSQL-Metadata-336791?logo=postgresql&logoColor=white" alt="PostgreSQL" />
  <img src="https://img.shields.io/badge/MQTT-Mosquitto-660066?logo=eclipsemosquitto&logoColor=white" alt="Mosquitto" />
  <img src="https://img.shields.io/badge/Kubernetes-k3s-326CE5?logo=kubernetes&logoColor=white" alt="Kubernetes" />
  <img src="https://img.shields.io/badge/tests-94_unit_+_13_integration-brightgreen" alt="tests" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-Apache_2.0-orange?logo=apache&logoColor=white" alt="Apache 2.0" />
  </a>
</p>

---

## What is Cenotoo?

Cenotoo is a **self-hosted, production-ready data platform** built for IoT and cyber-physical systems. It wires together Apache Kafka, Cassandra, Flink, PostgreSQL, and FastAPI into a single cohesive stack — with **MQTT, CoAP, and HTTP** ingestion paths, real-time SSE streaming, a device shadow system, a React web dashboard, and full Kubernetes observability on top.

There is no hosted version. You own your data, your infrastructure, and your pipeline.

**Deploy to Kubernetes / k3s in under 10 minutes with a single script.**

---

## 🗺️ Architecture

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                     Cenotoo Platform                        │
                    │                                                             │
  MQTT Devices ───► │  Mosquitto ──► MQTT Bridge ──────────────┐                 │
  CoAP Devices ───► │  CoAP Bridge  ───────────────────────────┤                 │
                    │                                           ▼                 │
  HTTP Clients ───► │  REST API (FastAPI) ──────────►   Kafka (KRaft)             │
   Web Browser ───► │  Dashboard (React SPA) ──► REST API   │      │              │
                    │  ├─ POST /send_data                   ▼      ▼              │
                    │  ├─ GET  /get_data                 Flink   Consumer         │
                    │  ├─ GET  /stream (SSE) ◄──┐        (SQL)    Bridge          │
                    │  ├─ GET  /statistics      │          │       │              │
                    │  ├─ CRUD /devices         │          └───┬───┘              │
                    │  ├─ GET  /shadow          │              ▼                  │
                    │  └─ PATCH /schema         └────────  Cassandra              │
                    │                                                             │
                    │  PostgreSQL (orgs · projects · users · keys · devices)      │
                    │                                                             │
                    │  ┌──────────────────────────────────────────────────────┐  │
                    │  │         Prometheus  ·  Grafana  ·  Alert Rules       │  │
                    │  └──────────────────────────────────────────────────────┘  │
                    └─────────────────────────────────────────────────────────────┘
```

---

## ✅ Features

| # | Feature | Endpoint | Status |
|---|---------|----------|:------:|
| 1 | **HTTP Data Ingestion** — single records or JSON arrays, schema-validated against collection definition | `POST /send_data` | ✅ |
| 2 | **MQTT Ingestion** — Mosquitto broker + bridge auto-routes any topic to Kafka; zero device-side config | broker port `1883` | ✅ |
| 3 | **CoAP Ingestion** — lightweight UDP ingestion for constrained devices with API key auth + HTTP health probe | `UDP /{org}/{project}/{collection}` | ✅ |
| 4 | **Historical Data Query** — field filters, time range, ordering, and pagination | `GET /get_data` | ✅ |
| 5 | **Time-series Statistics** — `avg`, `max`, `min`, `sum`, `count`, `distinct`, percentiles `p50`–`p99` over configurable intervals | `GET /statistics` | ✅ |
| 6 | **SSE Real-time Streaming** — live Kafka messages as Server-Sent Events with keepalive; starts from latest offset | `GET /stream` | ✅ |
| 7 | **Device Registry** — full CRUD device management scoped per project | `POST/GET/PUT/DELETE /devices` | ✅ |
| 8 | **Device Shadow / Twin** — separate `desired` and `reported` state per device; automatic `delta` computation | `GET/PUT /shadow` | ✅ |
| 9 | **Schema Evolution** — add or remove Cassandra columns on live tables with zero downtime | `PATCH /schema` | ✅ |
| 10 | **JWT + API Key Auth** — bearer tokens for users; scoped keys (`read`/`write`/`master`) for devices and services | `POST /token` | ✅ |
| 11 | **Stream Processing** — Apache Flink 1.18, Kafka source table, exactly-once semantics | Flink SQL | ✅ |
| 12 | **Observability** — Prometheus metrics, Grafana dashboards, alerting rules — all deployed in one script | kube-prometheus-stack | ✅ |
| 13 | **Rate Limiting** — configurable per-endpoint request limits | via `slowapi` | ✅ |
| 14 | **OpenTelemetry Tracing** — opt-in distributed tracing with any OTLP-compatible backend | `OTLP_ENDPOINT` env var | ✅ |
| 15 | **End-to-end Security** — SCRAM-SHA-512 on Kafka, `PasswordAuthenticator` on Cassandra, bcrypt user passwords | — | ✅ |
| 16 | **Collection Metrics** — health status, record count, and last ingested timestamp per collection | `GET /metrics` | ✅ |
| 18 | **Data Export** — download full collection data as CSV or Parquet | `GET /export` | ✅ |
| 19 | **Bulk Import** — upload CSV or JSON files with partial success handling and per-record error reporting | `POST /import` | ✅ |
| 20 | **Webhooks & Alerts** — define threshold rules that fire HTTP webhooks when data conditions are met | `CRUD /rules` | ✅ |
| 21 | **Web Dashboard** — React + Vite SPA for orgs, projects, collections, devices, API keys, live data, and dashboards | served via NodePort `30081` or HTTPS ingress | ✅ |
| 22 | **Guided Installer** — single interactive script provisions the full stack with preflight, plan-preview, and post-install verification | `scripts/install.sh` | ✅ |

---

## 🚀 Quick Start

### Recommended — guided installer

One interactive command provisions the entire stack on a fresh Ubuntu 22.04 / 24.04 host:

```bash
sudo ./scripts/install.sh
```

The installer walks you through:

- **Preflight** — OS / CPU / RAM / disk / Docker / dependency checks
- **Configuration** — exposure mode (NodePort *or* Ingress + Let's Encrypt), domain, secrets (auto-generated by default)
- **Plan** — full preview of every step before any change is made
- **Install** — orchestrates all numbered scripts in the correct order
- **Summary** — writes generated credentials to `.secrets/credentials.txt` (chmod 600)

Useful flags:

```bash
sudo ./scripts/install.sh --plan-only      # show plan, make no changes
sudo ./scripts/install.sh --resume         # use saved .install.conf
sudo ./scripts/install.sh --no-monitoring  # skip Prometheus + Grafana
sudo ./scripts/install.sh --uninstall      # remove the cenotoo namespace
```

> Deploying on **Google Cloud**? Follow the step-by-step **[GCP Deployment Guide](docs/gcp-deployment.md)** for VM sizing, firewall rules, and DNS setup.

### Manual — script-by-script

Every script is **idempotent** — safe to re-run and picks up where it left off.

```bash
sudo ./scripts/01-install-k3s.sh                 # k3s + Helm
sudo ./scripts/02-install-cert-manager.sh        # cert-manager (Flink + ingress TLS)
sudo ./scripts/03-install-strimzi-operator.sh    # Kafka (Strimzi) operator
sudo ./scripts/05-install-flink-operator.sh      # Flink operator
sudo ./scripts/06-install-monitoring.sh          # Prometheus + Grafana (optional)
sudo ./scripts/07-deploy-cenotoo.sh              # Kafka, Cassandra, consumers, Mosquitto
sudo ./scripts/24-deploy-postgres.sh             # PostgreSQL (metadata)
sudo ./scripts/08-deploy-api.sh                  # REST API
sudo ./scripts/10-deploy-dashboard.sh            # Web dashboard (optional)
sudo ./scripts/12-deploy-mqtt-bridge.sh          # MQTT ingestion (optional)
sudo ./scripts/22-deploy-coap-bridge.sh          # CoAP ingestion (optional)
sudo ./scripts/11-deploy-flink-jobs.sh           # Flink SQL gateway + jobs (optional)
sudo ./scripts/09-expose-api.sh                  # Public ingress + Let's Encrypt (optional)
```

> The Cassandra cluster is now a plain Kubernetes `StatefulSet` — no K8ssandra operator is required.

**Verify:**

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://${NODE_IP}:30080/health   # → {"status":"ok"}
curl http://${NODE_IP}:30080/docs     # Swagger UI
```

For the full walkthrough see the **[Deployment Guide](docs/k3s-setup.md)**.

---

## 📡 REST API

The [cenotoo-api](https://github.com/robotics-4-all/cenotoo-api) repository provides the full REST interface. Swagger UI is available at `http://<node-ip>:30080/docs` after deployment.

### Core Workflow

```bash
BASE="http://<node-ip>:30080/api/v1"

# Authenticate
TOKEN=$(curl -s -X POST "$BASE/token" \
  -d "username=admin&password=<pass>" | jq -r .access_token)

# Create a project and collection
PROJECT=$(curl -s -X POST "$BASE/projects" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
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

# Subscribe to the live stream
curl -N "$BASE/projects/$PROJECT/collections/<cid>/stream" \
  -H "X-API-Key: $WRITE_KEY"
```

### Endpoint Reference

| Endpoint | Method | Required Scope | Description |
|----------|--------|---------------|-------------|
| `/token` | `POST` | credentials | Obtain JWT access + refresh tokens |
| `/projects` | `POST/GET` | JWT | Create and list projects |
| `/projects/{pid}/keys` | `POST/GET` | JWT | Create and list scoped API keys |
| `/projects/{pid}/collections` | `POST/GET` | JWT | Create and list collections |
| `/projects/{pid}/collections/{cid}/send_data` | `POST` | `write` | Ingest single or batch records |
| `/projects/{pid}/collections/{cid}/get_data` | `GET` | `read` | Query with filters, pagination, time range |
| `/projects/{pid}/collections/{cid}/statistics` | `GET` | `read` | Aggregated stats and percentiles over intervals |
| `/projects/{pid}/collections/{cid}/stream` | `GET` | `read` | Live SSE stream from Kafka |
| `/projects/{pid}/collections/{cid}/schema` | `PATCH` | `master` | Add or remove fields with zero downtime |
| `/projects/{pid}/collections/{cid}/metrics` | `GET` | `read` | Health, record count, last ingested timestamp |
| `/projects/{pid}/collections/{cid}/export` | `GET` | `read` | Download as CSV or Parquet |
| `/projects/{pid}/collections/{cid}/import` | `POST` | `write` | Bulk upload CSV or JSON |
| `/projects/{pid}/collections/{cid}/rules` | `CRUD` | `master` | Webhook alert rules |
| `/projects/{pid}/devices` | `POST/GET` | `master` | Register and list devices |
| `/projects/{pid}/devices/{did}` | `GET/PUT/DELETE` | `master` | Device CRUD |
| `/projects/{pid}/devices/{did}/shadow` | `GET` | `read` | Full shadow: `desired`, `reported`, `delta` |
| `/projects/{pid}/devices/{did}/shadow/desired` | `PUT` | `write` | Set desired state (cloud → device) |
| `/projects/{pid}/devices/{did}/shadow/reported` | `PUT` | `write` | Update reported state (device → cloud) |

### API Key Scopes

| Scope | Permissions |
|-------|-------------|
| `read` | Query data, statistics, stream, metrics, export, shadow |
| `write` | All `read` permissions + ingest data, bulk import, update shadow reported state |
| `master` | All `write` permissions + schema changes, device management, webhook rules |

---

## 🔌 Device Ingestion

### MQTT

Any MQTT-capable device publishes with zero integration code. The bridge subscribes to `#` and routes every message automatically:

```bash
mosquitto_pub -h <broker-ip> -p 1883 \
  -t "myorg/myproject/sensors" \
  -m '{"temp": 22.5, "humidity": 58, "node": "roof-01"}'
```

Topic format `{org}/{project}/{collection}` maps to Kafka topic `{org}.{project}.{collection}` → Cassandra table `{project}_{collection}` in keyspace `{org}`.

### CoAP

Lightweight UDP ingestion for constrained devices. API key auth is inline — no separate handshake:

```bash
coap-client -m post \
  "coap://<broker-ip>/myorg/myproject/sensors?key=<api_key>" \
  -e '{"temp": 22.5}'
```

An HTTP health probe is available at `http://<coap-bridge-ip>:8080/health`.

### HTTP

For server-to-server ingestion or any client that already speaks HTTP, post directly to the REST API. See the [REST API](#-rest-api) section for the full workflow.

---

## 🖥️ Web Dashboard

The optional [cenotoo-dashboard](https://github.com/robotics-4-all/cenotoo-dashboard) is a React + Vite SPA that ships with Cenotoo. It provides:

- Login + JWT session management
- Organization, project, and collection browser
- Device registry, API key generator (with scope selection), webhook rule editor
- Live data view (SSE), historical query builder, statistics charts
- Schema editor with live preview

Deploy it with:

```bash
sudo ./scripts/10-deploy-dashboard.sh
```

The dashboard is exposed on **NodePort `30081`** by default, and can be put behind the same Traefik + Let's Encrypt ingress as the API via `scripts/09-expose-api.sh`.

> The API base URL (`VITE_API_URL`) is baked into the SPA bundle at build time. If you switch from NodePort to ingress (or change the domain), re-run `10-deploy-dashboard.sh` to rebuild with the new URL.

---

## 🗄️ System Components

| Component | Role | Technology | K8s Resource |
|-----------|------|------------|:------------:|
| Kafka | Message streaming backbone | Apache Kafka 3.x (KRaft) | Strimzi operator |
| Cassandra | Time-series data persistence | Apache Cassandra 4.x | StatefulSet |
| PostgreSQL | Metadata — orgs, projects, users, API keys, rules | PostgreSQL 15 | StatefulSet |
| Flink | Stream processing | Apache Flink 1.18 | Flink operator |
| REST API | HTTP interface + auth | FastAPI + Pydantic | Deployment |
| Web Dashboard | Browser UI | React + Vite + nginx | Deployment |
| MQTT Bridge | MQTT → Kafka routing | Python + paho-mqtt | Deployment |
| CoAP Bridge | CoAP → Kafka routing | Python + aiocoap | Deployment |
| Consumer Bridge | Kafka → Cassandra writer | Python + confluent-kafka | Deployment |
| Live Consumer | Kafka → SSE relay | Python + confluent-kafka | Deployment |
| Mosquitto | MQTT broker | Eclipse Mosquitto | StatefulSet |
| Prometheus | Metrics collection | kube-prometheus-stack | — |
| Grafana | Dashboards + alerting | kube-prometheus-stack | — |

---

## ⚙️ Configuration

### Secrets

All credentials and cluster parameters are managed as Kubernetes Secrets and ConfigMaps under `deploy/k8s/01-secrets/`. The guided installer generates them automatically; for manual deploys, copy the example files and fill in your values:

```bash
cp deploy/k8s/01-secrets/api-secrets.yaml.example deploy/k8s/01-secrets/api-secrets.yaml
# edit values, then:
kubectl apply -f deploy/k8s/01-secrets/
```

The installer writes the generated values to `.secrets/credentials.txt` (chmod 600).

### Reset the admin user

```bash
sudo ./scripts/reset-admin.sh
```

Interactively rotates the dashboard / API admin username and password directly in PostgreSQL. Useful if you forget the auto-generated password or want to rename the bootstrap account.

### Naming Conventions

| Entity | Pattern | Example |
|--------|---------|---------|
| Kafka topic | `{org}.{project}.{collection}` | `acme.iot.sensors` |
| Cassandra keyspace | `{org}` | `acme` |
| Cassandra table | `{project}_{collection}` | `iot_sensors` |
| Consumer group | `{topic}_cassandra_writer` | `acme.iot.sensors_cassandra_writer` |
| API key scope | `read` / `write` / `master` | scoped per project |

---

## 🧪 Testing

Run all 13 integration suites against a live cluster with a single command:

```bash
export CENOTOO_ADMIN_PASSWORD=<your-password>
bash scripts/run-all-tests.sh
```

| Suite | Script | Tests |
|-------|--------|------:|
| Smoke | `smoke-test.sh` | 16 |
| Infrastructure | `integration-test.sh` | — |
| PostgreSQL | `25-test-postgres.sh` | 33 |
| MQTT | `13-test-mqtt.sh` | — |
| CoAP | `23-test-coap.sh` | 24 |
| SSE Streaming | `14-test-sse-stream.sh` | 12 |
| Device Management | `15-test-device-management.sh` | 24 |
| Schema Evolution | `16-test-schema-evolution.sh` | 21 |
| Collection Metrics | `17-test-collection-metrics.sh` | — |
| Data Export | `18-test-data-export.sh` | — |
| Bulk Import | `19-test-bulk-import.sh` | — |
| Webhooks | `20-test-webhooks.sh` | — |
| Statistics | `21-test-statistics.sh` | 34 |

Unit tests (no infrastructure required):

```bash
pytest tests/ -v   # 94 tests — mocks Kafka, Cassandra, MQTT auth, CoAP
```

The guided installer (`scripts/install.sh`) automatically runs the smoke test after install, and prompts whether to also run the full 13-suite integration battery.

---

## 🛠️ Tech Stack

| Layer | Technology | Notes |
|-------|------------|-------|
| Message Streaming | Apache Kafka (KRaft) | No ZooKeeper; replication factor 2 |
| Stream Processing | Apache Flink 1.18 | Exactly-once; K8s-native HA in production |
| Time-series Storage | Apache Cassandra 4.x | Plain `StatefulSet`, `NetworkTopologyStrategy`, partition key `(day, key)` |
| Metadata Storage | PostgreSQL 15 | Orgs, projects, users, API keys, device registry, rules |
| REST API | FastAPI + Pydantic | Swagger UI, ReDoc, OAuth2, rate limiting |
| Web Dashboard | React + Vite | Served by nginx, exposed via NodePort or Traefik ingress |
| MQTT Broker | Eclipse Mosquitto | `mosquitto-go-auth` HTTP backend authenticates against `cenotoo-api` |
| CoAP Bridge | aiocoap | Plaintext UDP only (DTLS experimental, not supported) |
| Kafka Operator | Strimzi 0.51+ | KRaft, KafkaNodePools, SCRAM-SHA-512 ACLs |
| Flink Operator | Apache Flink K8s Operator 1.14+ | K8s-native HA, PVC-backed checkpoints |
| Ingress | Traefik (k3s built-in) + cert-manager | Let's Encrypt HTTP-01 for API + dashboard |
| Observability | Prometheus + Grafana | JMX exporters for Kafka + Flink, alerting rules |
| Tracing | OpenTelemetry | Opt-in via `OTLP_ENDPOINT` |
| Rate Limiting | slowapi | Per-endpoint, configurable |
| CI/CD | GitHub Actions | Lint → typecheck → unit + integration tests on push/PR |

---

## Contributing

Contributions, issues, and feature requests are welcome.

- Check [open issues](../../issues) before opening a new one
- Follow the existing code style: `ruff check .` and `ruff format .`
- All Python code must pass `mypy` and the full test suite
- New features must include integration tests in `scripts/`

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
