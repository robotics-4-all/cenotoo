# PROJECT KNOWLEDGE BASE

**Generated:** 2026-03-07
**Commit:** 07b0583
**Branch:** devel

## OVERVIEW

Cenotoo — distributed data streaming platform (Kafka + Cassandra + Flink) deployed on Kubernetes (k3s) with Strimzi, K8ssandra, Flink Operator, Prometheus/Grafana observability, and Medusa backups. Python consumers bridge Kafka→Cassandra. Flink SQL prepared for future stream processing. Pure infrastructure-as-code with utility scripts.

## STRUCTURE

```
cenotoo/
├── kafka-to-cassandra/         # Consumer: Kafka→Cassandra writer (self-contained Docker service)
│   ├── consumer.py             # Polls Kafka, inserts JSON into Cassandra tables dynamically
│   ├── Dockerfile
│   └── requirements.txt        # confluent_kafka, cassandra-driver
├── kafka-live-consumer/        # Consumer: Kafka→stdout (real-time message viewer)
│   ├── consumer.py             # Polls Kafka latest offset, logs messages
│   ├── Dockerfile
│   └── requirements.txt        # confluent_kafka only
├── mqtt-bridge/                # MQTT ingestion plugin: Mosquitto→Kafka bridge
│   ├── mqtt_bridge.py          # Subscribes to # wildcard, wraps payloads in JSON envelope, produces to Kafka
│   ├── Dockerfile
│   └── requirements.txt        # paho-mqtt, confluent_kafka
├── coap-bridge/                # CoAP ingestion plugin: aiocoap server→Kafka bridge (auth inline)
│   ├── coap_bridge.py          # POST /{org}/{project}/{collection}?key=<api_key> → Kafka; HTTP health on :8080
│   ├── Dockerfile
│   └── requirements.txt        # aiocoap, confluent_kafka, cassandra-driver, flask
├── flink/
│   ├── Dockerfile              # flink:1.18.1 + PyFlink 1.18.1 + SQL Kafka connector JAR
│   └── sql/
│       └── kafka_source.sql    # Flink SQL Kafka source table definition
├── scripts/
│   ├── 01-install-k3s.sh               # k3s install + kubeconfig + Helm
│   ├── 02-install-cert-manager.sh      # cert-manager (K8ssandra prerequisite)
│   ├── 03-install-strimzi-operator.sh  # Strimzi Kafka operator
│   ├── 04-install-k8ssandra-operator.sh # K8ssandra Cassandra operator
│   ├── 05-install-flink-operator.sh    # Flink Kubernetes operator
│   ├── 06-install-monitoring.sh        # kube-prometheus-stack (optional)
│   ├── 07-deploy-cenotoo.sh            # Deploy Cenotoo on k3s
│   └── build-images.sh                 # Builds Docker images + imports into k3s containerd
├── tests/                      # pytest test suite (493 tests)
│   ├── conftest.py             # Shared mock fixtures (Kafka, Cassandra)
│   ├── test_cassandra_writer.py
│   ├── test_live_consumer.py
│   ├── test_mqtt_bridge.py
│   └── test_coap_bridge.py
├── deploy/
│   └── k8s/                    # Kubernetes manifests (plain YAML, no Helm)
│       ├── 00-namespace.yaml
│       ├── 01-secrets/         # Credentials + API secrets (.yaml.example templates provided)
│       ├── 02-kafka/           # Strimzi Kafka CR + KafkaUser CR (SCRAM-SHA-512, ACLs)
│       ├── 03-cassandra/       # Cassandra StatefulSet + service
│       ├── 04-flink/           # FlinkDeployment CR (K8s-native HA) + PVC + RBAC
│       ├── 05-consumers/       # cassandra-writer + live-consumer Deployments
│       ├── 07-api/             # REST API Deployment + Service
│       ├── 08-dashboard/       # Dashboard Deployment + Service
│       ├── 09-mqtt/            # Mosquitto StatefulSet + ConfigMap + mqtt-bridge Deployment
│       ├── 10-coap/            # CoAP bridge Deployment + Service
│       └── 11-postgres/        # PostgreSQL StatefulSet + ConfigMap + PVC
├── pyproject.toml              # ruff + mypy + pytest config
├── .pre-commit-config.yaml     # ruff + pre-commit hooks
└── .github/workflows/ci.yml   # CI: lint → typecheck → test
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add Flink SQL jobs | `flink/sql/` | Submit via `sql-client.sh -f`; no native Cassandra sink — use DataStream API |
| Change consumer logic | `kafka-to-cassandra/consumer.py` or `kafka-live-consumer/consumer.py` | Each is self-contained |
| Add new Docker image | `scripts/build-images.sh` | Add new build block + create `<service>/Dockerfile` |
| Add/run tests | `tests/` | `pytest tests/ -v` — uses importlib for module isolation |
| Lint/format | `pyproject.toml` | `ruff check .` and `ruff format .` |
| CI pipeline | `.github/workflows/ci.yml` | Runs on push/PR to main: lint → typecheck → test |
| K8s deployment | `deploy/k8s/` | Plain manifests — apply with `07-deploy-cenotoo.sh` |
| Kafka K8s config | `deploy/k8s/02-kafka/` | Strimzi Kafka CR + KafkaUser CR with SCRAM-SHA-512 |
| Cassandra K8s config | `deploy/k8s/03-cassandra/` | Cassandra StatefulSet + service |
| Flink K8s config | `deploy/k8s/04-flink/` | FlinkDeployment CR (K8s-native HA, no ZooKeeper) + PVC |
| Consumer K8s config | `deploy/k8s/05-consumers/` | Standard K8s Deployments with secret refs |
| K8s monitoring | `templates/monitoring/` | PodMonitors, PrometheusRules, Grafana dashboards, Kafka metrics ConfigMap |
| Credentials / secrets | `deploy/k8s/01-secrets/` | Copy `.yaml.example` files, fill values, apply before deploying |

## CONVENTIONS

- **Topic naming**: `{org}.{project}.{collection}` (see consumer.py files)
- **Cassandra table naming**: `{project}_{collection}` within org-named keyspace
- **Consumer group IDs**: `{topic}_cassandra_writer` (kafka-to-cassandra), `{project}.{collection}_live_group` (live consumer)
- **Docker image tags**: hardcoded in `build-images.sh` — `custom-flink-image`, `kafka-cassandra-consumer`, `kafka-live-consumer`, `mqtt-auth`, `mqtt-bridge`, `coap-bridge`
- **Image deployment**: `build-images.sh` always imports into k3s containerd and rolls out deployments; run after any service code change
- **Credentials / config**: managed as k8s Secrets and ConfigMaps under `deploy/k8s/01-secrets/` — never in env files
- **Python style**: No packages/modules, no type hints — consumers use `logging` module, init script uses `print()`
- **Linting**: ruff (configured in `pyproject.toml`) — run `ruff check .` and `ruff format .`
- **Testing**: pytest with `importlib`-based module loading (avoids `consumer.py` name collision between kafka-to-cassandra and kafka-live-consumer)
- **Replication factor**: 2 everywhere (Kafka offsets, transactions, Cassandra keyspace)
- **Cassandra replication**: NetworkTopologyStrategy (configurable via `CASSANDRA_DC` and `CASSANDRA_RF` env vars)

## ANTI-PATTERNS (THIS PROJECT)

- **Flink SQL has no native Cassandra sink** — writing to Cassandra requires Java/Scala DataStream API with `CassandraSink`, not pure SQL
- **aiocoap DTLS is highly experimental** — do NOT use it; plaintext UDP only for CoAP bridge
- **MUST NOT name any Python file consumer.py** — pytest importlib isolation will break on duplicate module names
- **CoAP auth is inline in coap-bridge** — no sidecar needed (unlike MQTT which requires mqtt-auth sidecar for Mosquitto go-auth plugin)

## COMMANDS

```bash
# k3s bootstrap (run scripts in order)
./scripts/01-install-k3s.sh
./scripts/02-install-cert-manager.sh
./scripts/03-install-strimzi-operator.sh
./scripts/04-install-k8ssandra-operator.sh
./scripts/05-install-flink-operator.sh
./scripts/06-install-monitoring.sh       # optional
./scripts/07-deploy-cenotoo.sh
./scripts/22-deploy-coap-bridge.sh   # CoAP bridge (optional)

# Build all Docker images and import into k3s containerd
bash scripts/build-images.sh

# Force full rebuild (bust Docker layer cache)
bash scripts/build-images.sh --no-cache

# Dev: lint + test
ruff check . && ruff format --check . && pytest tests/ -v
```

## NOTES

- Kafka uses KRaft mode — no ZooKeeper dependency anywhere in the stack.
- Cassandra auth is now enabled (`PasswordAuthenticator`) — default creds `cassandra/cassandra`, must be changed after first boot.
- Consumers now use structured logging, graceful SIGTERM shutdown, and validated CQL identifiers.
- `kafka-to-cassandra` uses manual offset commits — only commits after successful Cassandra write.
