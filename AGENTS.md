# PROJECT KNOWLEDGE BASE

**Generated:** 2026-03-07
**Commit:** 07b0583
**Branch:** devel

## OVERVIEW

Cenotoo — distributed data streaming platform (Kafka + Cassandra + Flink) with dual deployment targets: Docker Compose (dev, no ZooKeeper, simplified Flink) and Kubernetes (Helm chart with Strimzi, K8ssandra, Flink Operator, Prometheus/Grafana observability, Medusa backups). Python consumers bridge Kafka→Cassandra. Flink SQL prepared for future stream processing. Pure infrastructure-as-code with utility scripts.

## STRUCTURE

```
centoo/
├── docker-compose.yaml        # All services: kafka×2, cassandra×2, flink×2 (no ZooKeeper)
├── .env.example                # Node-specific IPs (must cp to .env on each node)
├── requirements.txt            # Root deps: cassandra-driver, python-dotenv
├── kafka/
│   └── kafka.jaas.conf         # SASL/PLAIN auth config (uses env vars for creds)
├── kafka-to-cassandra/         # Consumer: Kafka→Cassandra writer (self-contained Docker service)
│   ├── consumer.py             # Polls Kafka, inserts JSON into Cassandra tables dynamically
│   ├── Dockerfile
│   └── requirements.txt        # confluent_kafka, cassandra-driver
├── kafka-live-consumer/        # Consumer: Kafka→stdout (real-time message viewer)
│   ├── consumer.py             # Polls Kafka latest offset, logs messages
│   ├── Dockerfile
│   └── requirements.txt        # confluent_kafka only
├── flink/
│   ├── Dockerfile              # flink:1.18.1 + PyFlink 1.18.1 + SQL Kafka connector JAR
│   └── sql/
│       └── kafka_source.sql    # Flink SQL Kafka source table definition
├── cassandra/
│   └── create_cassandra_tables.py  # Schema init: metadata keyspace + 5 tables
├── scripts/
│   ├── 01-install-k3s.sh       # k3s install + kubeconfig + Helm
│   ├── 02-install-cert-manager.sh      # cert-manager (K8ssandra prerequisite)
│   ├── 03-install-strimzi-operator.sh  # Strimzi Kafka operator
│   ├── 04-install-k8ssandra-operator.sh # K8ssandra Cassandra operator
│   ├── 05-install-flink-operator.sh    # Flink Kubernetes operator
│   ├── 06-install-monitoring.sh        # kube-prometheus-stack (optional)
│   ├── 07-deploy-cenotoo.sh    # Deploy Cenotoo Helm chart on k3s
│   ├── build-images.sh         # Builds 3 Docker images (flink, kafka-to-cassandra, kafka-live-consumer)
│   └── generate-cluster-id.py  # UUID→base64 Kafka cluster ID generator
├── tests/                      # pytest test suite (21 tests)
│   ├── conftest.py             # Shared mock fixtures (Kafka, Cassandra)
│   ├── test_cassandra_writer.py
│   ├── test_live_consumer.py
│   └── test_cluster_id.py
├── deploy/
│   └── helm/
│       └── cenotoo/                # Helm chart for Kubernetes deployment
│           ├── Chart.yaml
│           ├── values.yaml         # Default values (all configurable parameters)
│           ├── values-staging.yaml
│           ├── values-production.yaml
│           └── templates/
│               ├── _helpers.tpl
│               ├── kafka/
│               │   ├── kafka-cluster.yaml   # Strimzi Kafka CR (KRaft, NodePools, SASL)
│               │   └── kafka-user.yaml      # Strimzi KafkaUser CR (SCRAM-SHA-512, ACLs)
│               ├── cassandra/
│               │   ├── k8ssandra-cluster.yaml  # K8ssandraCluster CR (auth, 2 nodes, Medusa backup)
│               │   └── superuser-secret.yaml   # Cassandra superuser credentials
│               ├── flink/
│               │   ├── flink-deployment.yaml   # FlinkDeployment CR (K8s-native HA)
│               │   ├── flink-pvc.yaml          # PVC for HA + checkpoints + savepoints
│               │   └── flink-rbac.yaml         # ServiceAccount + Role + RoleBinding for Flink
│               ├── consumers/
│               │   ├── cassandra-writer.yaml   # Deployment: kafka-to-cassandra
│               │   └── live-consumer.yaml      # Deployment: kafka-live-consumer
│               ├── monitoring/
│               │   ├── kafka-metrics-configmap.yaml  # JMX Prometheus Exporter rules for Kafka
│               │   ├── pod-monitors.yaml             # PodMonitors: Kafka, KafkaExporter, Flink
│               │   ├── prometheus-rules.yaml          # PrometheusRule: alerting rules
│               │   └── grafana-dashboards-configmap.yaml  # Grafana overview dashboard
│               └── secrets/
│                   └── kafka-credentials.yaml  # Kafka auth credentials
├── pyproject.toml              # ruff + mypy + pytest config
├── .pre-commit-config.yaml     # ruff + pre-commit hooks
└── .github/workflows/ci.yml   # CI: lint → typecheck → test
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add/modify a service | `docker-compose.yaml` | 6 services: kafka×2, cassandra×2, flink JM+TM |
| Add Flink SQL jobs | `flink/sql/` | Submit via `sql-client.sh -f`; no native Cassandra sink — use DataStream API |
| Change Cassandra schema | `cassandra/create_cassandra_tables.py` | Run on ONE node only |
| Modify Kafka auth | `kafka/kafka.jaas.conf` | Creds via `$KAFKA_USERNAME`, `$KAFKA_PASSWORD` env vars |
| Change consumer logic | `kafka-to-cassandra/consumer.py` or `kafka-live-consumer/consumer.py` | Each is self-contained |
| Add new Docker image | `scripts/build-images.sh` | Add new build block + create `<service>/Dockerfile` |
| Configure node IPs | `.env` (from `.env.example`) | Different per node; see README for Node 1 vs Node 2 examples |
| Generate cluster ID | `scripts/generate-cluster-id.py` | Run once, copy ID to both nodes' `.env` |
| Add/run tests | `tests/` | `pytest tests/ -v` — uses importlib for module isolation |
| Lint/format | `pyproject.toml` | `ruff check .` and `ruff format .` |
| CI pipeline | `.github/workflows/ci.yml` | Runs on push/PR to main: lint → typecheck → test |
| K8s deployment | `deploy/helm/cenotoo/` | `helm install cenotoo deploy/helm/cenotoo/` — requires Strimzi, K8ssandra, Flink operators |
| K8s config overrides | `values-staging.yaml`, `values-production.yaml` | `helm install -f values-production.yaml` |
| Kafka K8s config | `templates/kafka/` | Strimzi Kafka CR + KafkaUser CR with SCRAM-SHA-512 |
| Cassandra K8s config | `templates/cassandra/` | K8ssandra CR + superuser secret |
| Flink K8s config | `templates/flink/` | FlinkDeployment CR (K8s-native HA, no ZooKeeper) + PVC |
| Consumer K8s config | `templates/consumers/` | Standard K8s Deployments with secret refs |
| K8s monitoring | `templates/monitoring/` | PodMonitors, PrometheusRules, Grafana dashboards, Kafka metrics ConfigMap |
| Monitoring config | `values.yaml` → `monitoring:` | Toggle metrics, alerts, dashboards per component |
| Backup config | `values.yaml` → `backup:` | Medusa backup for Cassandra (disabled by default) |

## CONVENTIONS

- **Topic naming**: `{org}.{project}.{collection}` (see consumer.py files)
- **Cassandra table naming**: `{project}_{collection}` within org-named keyspace
- **Consumer group IDs**: `{topic}_cassandra_writer` (kafka-to-cassandra), `{project}.{collection}_live_group` (live consumer)
- **Docker image tags**: hardcoded in `build-images.sh` — `custom-flink-image`, `kafka-cassandra-consumer`, `kafka-live-consumer`
- **Environment-driven config**: All IPs, ports, credentials passed via env vars — never hardcoded
- **Python style**: No packages/modules, no type hints — consumers use `logging` module, init script uses `print()`
- **Linting**: ruff (configured in `pyproject.toml`) — run `ruff check .` and `ruff format .`
- **Testing**: pytest with `importlib`-based module loading (avoids `consumer.py` name collision between kafka-to-cassandra and kafka-live-consumer)
- **Replication factor**: 2 everywhere (Kafka offsets, transactions, Cassandra keyspace)
- **Cassandra replication**: NetworkTopologyStrategy (configurable via `CASSANDRA_DC` and `CASSANDRA_RF` env vars)

## ANTI-PATTERNS (THIS PROJECT)

- **Flink SQL has no native Cassandra sink** — writing to Cassandra requires Java/Scala DataStream API with `CassandraSink`, not pure SQL

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

# Generate Kafka cluster ID (run once, Docker Compose only)
python scripts/generate-cluster-id.py

# Build all Docker images
bash scripts/build-images.sh

# Node 1: start services
docker-compose up -d kafka1 cassandra1 jobmanager taskmanager

# Node 2: start services
docker-compose up -d kafka2 cassandra2

# Init Cassandra schema (one node only, after Cassandra is healthy)
pip install -r requirements.txt
python cassandra/create_cassandra_tables.py

# Dev: lint + test
ruff check . && ruff format --check . && pytest tests/ -v
```

## NOTES

- Two-node deployment: each node runs a subset of services. `.env` must be customized per node.
- Kafka uses KRaft mode — no ZooKeeper dependency anywhere in the stack.
- `docker-compose.yaml` uses modern format (no deprecated `version` field).
- Docker Compose Flink runs single JobManager (no HA) — production uses K8s-native HA.
- All Docker Compose services include health checks with `depends_on` conditions.
- Cassandra auth is now enabled (`PasswordAuthenticator`) — default creds `cassandra/cassandra`, must be changed after first boot.
- Consumers now use structured logging, graceful SIGTERM shutdown, and validated CQL identifiers.
- `kafka-to-cassandra` uses manual offset commits — only commits after successful Cassandra write.
