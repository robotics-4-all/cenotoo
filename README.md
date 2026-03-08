<p align="center">
  <img src=".github/assets/cenotoo_landing.png" alt="Cenotoo" width="100%" />
</p>

<h1 align="center">Cenotoo</h1>

<p align="center">
  <strong>Production-grade distributed data streaming platform.</strong><br/>
  Ingest, process, and persist real-time data at scale — from development to production in minutes.
</p>

<p align="center">
  <a href="#quick-start"><img src="https://img.shields.io/badge/get_started-blue?style=for-the-badge" alt="Get Started" /></a>
  <a href="docs/k3s-setup.md"><img src="https://img.shields.io/badge/deployment_guide-teal?style=for-the-badge" alt="Deployment Guide" /></a>
  <a href="#architecture"><img src="https://img.shields.io/badge/architecture-slategray?style=for-the-badge" alt="Architecture" /></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Kafka-KRaft-blue?logo=apachekafka&logoColor=white" alt="Kafka KRaft" />
  <img src="https://img.shields.io/badge/Cassandra-4.x-1287B1?logo=apachecassandra&logoColor=white" alt="Cassandra" />
  <img src="https://img.shields.io/badge/Flink-1.18-E6526F?logo=apacheflink&logoColor=white" alt="Flink" />
  <img src="https://img.shields.io/badge/Kubernetes-k3s-326CE5?logo=kubernetes&logoColor=white" alt="Kubernetes" />
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker Compose" />
</p>

---

## Why Cenotoo?

Building a real-time data pipeline shouldn't require months of infrastructure work. Cenotoo packages battle-tested distributed systems into a single, opinionated platform that works out of the box.

| | What you get |
|---|---|
| **Kafka (KRaft)** | High-throughput message streaming — no ZooKeeper, no operational overhead |
| **Cassandra** | Horizontally scalable persistence with tunable consistency |
| **Flink** | Stateful stream processing with exactly-once semantics |
| **Dual Deploy** | Same stack, same code — Docker Compose for dev, Kubernetes for production |
| **Security First** | SCRAM-SHA-512 auth on Kafka, PasswordAuthenticator on Cassandra, end-to-end |
| **Observability** | Prometheus metrics, Grafana dashboards, alerting rules — built in |

---

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │              Cenotoo Platform               │
                         │                                             │
  Producers ───────────► │  ┌─────────┐    ┌─────────┐    ┌─────────┐ │
                         │  │  Kafka   │───►│  Flink  │───►│Cassandra│ │
                         │  │ (KRaft)  │    │  (SQL)  │    │  (CQL)  │ │
                         │  └────┬─────┘    └─────────┘    └────▲────┘ │
                         │       │                              │      │
                         │       └──── Consumer Bridge ─────────┘      │
                         │              (Python)                       │
                         │                                             │
                         │  ┌──────────────────────────────────────┐   │
                         │  │  Prometheus  ·  Grafana  ·  Alerts   │   │
                         │  └──────────────────────────────────────┘   │
                         └─────────────────────────────────────────────┘
```

### Deployment Targets

| | Docker Compose | Kubernetes (k3s) |
|---|---|---|
| **Use case** | Development & testing | Staging & production |
| **Kafka** | 2 brokers, KRaft | Strimzi operator, KafkaNodePools |
| **Cassandra** | 2 nodes, local volumes | StatefulSet, persistent storage |
| **Flink** | Single JobManager | Operator-managed, K8s-native HA |
| **Monitoring** | — | Prometheus + Grafana stack |
| **Setup time** | ~2 minutes | ~10 minutes |

---

## Quick Start

### Docker Compose (Development)

```bash
# 1. Configure
cp .env.example .env              # Edit with your node IPs
python scripts/generate-cluster-id.py  # Copy output to .env

# 2. Build & Launch
bash scripts/build-images.sh
docker-compose up -d kafka1 cassandra1 jobmanager taskmanager  # Node 1
docker-compose up -d kafka2 cassandra2                          # Node 2

# 3. Initialize schema
pip install -r requirements.txt
python cassandra/create_cassandra_tables.py

# 4. Verify
docker ps  # All containers should show (healthy)
```

### Kubernetes (Production)

Bootstrap scripts handle the full installation — operators, manifests, and verification:

```bash
sudo ./scripts/01-install-k3s.sh               # k3s cluster + Helm
sudo ./scripts/02-install-cert-manager.sh      # TLS certificates
sudo ./scripts/03-install-strimzi-operator.sh  # Kafka operator
sudo ./scripts/05-install-flink-operator.sh    # Flink operator
sudo ./scripts/06-install-monitoring.sh        # Prometheus + Grafana (optional)
./scripts/build-images.sh --k3s               # Build + import images
sudo ./scripts/07-deploy-cenotoo.sh            # Deploy platform
```

Every script is **idempotent** — safe to re-run at any time.

```bash
# Verify deployment
sudo ./scripts/smoke-test.sh        # Pod health, CRDs, services
sudo ./scripts/integration-test.sh  # End-to-end data flow
```

For the complete walkthrough, see the **[Deployment Guide](docs/k3s-setup.md)**.

---

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KAFKA_BROKER1_IP` | Kafka broker 1 address | — |
| `KAFKA_BROKER2_IP` | Kafka broker 2 address | — |
| `KAFKA_CLUSTER_ID` | KRaft cluster identifier | Generated via script |
| `KAFKA_USERNAME` | SASL authentication username | `admin` |
| `KAFKA_PASSWORD` | SASL authentication password | — |
| `CASSANDRA_SEEDS` | Cassandra contact points | — |
| `CASSANDRA_DC` | Datacenter name | `datacenter1` |
| `CASSANDRA_RF` | Replication factor | `2` |

### Conventions

| Convention | Pattern | Example |
|------------|---------|---------|
| Kafka topics | `{org}.{project}.{collection}` | `acme.iot.sensors` |
| Cassandra keyspace | `{org}` | `acme` |
| Cassandra tables | `{project}_{collection}` | `iot_sensors` |
| Consumer groups | `{topic}_cassandra_writer` | `acme.iot.sensors_cassandra_writer` |

---

## Project Structure

```
centoo/
├── kafka/                      # Kafka SASL/PLAIN auth configuration
├── kafka-to-cassandra/         # Consumer: Kafka → Cassandra bridge
├── kafka-live-consumer/        # Consumer: Kafka → stdout (debug)
├── flink/                      # Flink image + SQL job definitions
├── cassandra/                  # Schema initialization script
├── deploy/
│   └── k8s/                    # Raw Kubernetes manifests
│       ├── 00-namespace.yaml
│       ├── 01-secrets/
│       ├── 02-kafka/           # Strimzi Kafka + KafkaUser CRs
│       ├── 03-cassandra/       # StatefulSet + Service
│       ├── 04-flink/           # FlinkDeployment CR + RBAC + PVC
│       └── 05-consumers/       # Deployment manifests
├── scripts/                    # Bootstrap, build, test scripts
├── tests/                      # pytest suite (26 tests)
├── docs/                       # Deployment guides
└── docker-compose.yaml         # Development environment
```

---

## Development

```bash
# Lint & format
ruff check . && ruff format --check .

# Run test suite
pytest tests/ -v

# Full CI pipeline (mirrors GitHub Actions)
ruff check . && ruff format --check . && pytest tests/ -v
```

---

## Tech Stack

| Component | Technology | Version |
|-----------|------------|---------|
| Message Streaming | Apache Kafka (KRaft) | 4.x |
| Stream Processing | Apache Flink | 1.18 |
| Persistence | Apache Cassandra | 4.x |
| Container Orchestration | Kubernetes (k3s) | Latest |
| Kafka Operator | Strimzi | 0.45+ |
| Flink Operator | Apache Flink K8s Operator | 1.10+ |
| Monitoring | Prometheus + Grafana | kube-prometheus-stack |
| CI/CD | GitHub Actions | — |
| Linting | Ruff | — |

---

## License

This project is proprietary. All rights reserved.
