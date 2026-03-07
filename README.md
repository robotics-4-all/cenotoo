# **Cenotoo**

A distributed data streaming platform (Kafka + Cassandra + Flink) with dual deployment targets: Docker Compose for development and Kubernetes (Helm) for production.

---

## **Table of Contents**
1. [System Architecture](#system-architecture)
2. [Prerequisites](#prerequisites)
3. [Quick Start (Docker Compose)](#quick-start-docker-compose)
4. [Kubernetes Deployment](#kubernetes-deployment)
5. [Initializing Cassandra](#initializing-cassandra)
6. [Development](#development)
7. [Additional Notes](#additional-notes)

---

## **System Architecture**

### Docker Compose (Development)

- Kafka Broker 1 + Broker 2 (KRaft mode, no ZooKeeper)
- Cassandra Node 1 + Node 2 (PasswordAuthenticator)
- Flink JobManager + TaskManager (single instance, no HA)
- Custom consumers: `kafka-to-cassandra`, `kafka-live-consumer`

All services include health checks. Cassandra 2 waits for Cassandra 1, TaskManager waits for JobManager.

### Kubernetes (Production)

Deployed via Helm chart (`deploy/helm/cenotoo/`) using:
- **Strimzi** for Kafka (KRaft, SCRAM-SHA-512, KafkaNodePools)
- **K8ssandra** for Cassandra (PasswordAuthenticator, optional Medusa backups)
- **Flink Operator** for Flink (K8s-native HA, checkpoints, savepoints)
- **Prometheus + Grafana** for observability (PodMonitors, alerting rules, dashboards)

---

## **Prerequisites**

### Docker Compose
- **Docker** (>= 20.10)
- **Docker Compose** (>= 1.29)
- **Python** (>= 3.8) — for Cassandra schema init

### Kubernetes
- **kubectl** + cluster access
- **Helm** (>= 3.x)
- Pre-installed operators: Strimzi, K8ssandra (with cert-manager), Flink Operator
- Optional: kube-prometheus-stack (for monitoring)

---

## **Quick Start (Docker Compose)**

1. **Configure environment**:
   ```bash
   cp .env.example .env
   # Edit .env with your node IPs
   ```

2. **Generate Kafka Cluster ID** (once):
   ```bash
   python scripts/generate-cluster-id.py
   # Copy the output to KAFKA_CLUSTER_ID in .env
   ```

3. **Build custom Docker images**:
   ```bash
   bash scripts/build-images.sh
   ```

4. **Start all services**:
   ```bash
   # Node 1
   docker-compose up -d kafka1 cassandra1 jobmanager taskmanager

   # Node 2
   docker-compose up -d kafka2 cassandra2
   ```

5. **Initialize Cassandra schema** (after Cassandra is healthy):
   ```bash
   pip install -r requirements.txt
   python cassandra/create_cassandra_tables.py
   ```

6. **Verify health**:
   ```bash
   docker ps    # All containers should show (healthy)
   ```

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `KAFKA_BROKER1_IP` | Kafka broker 1 IP | `192.168.1.101` |
| `KAFKA_BROKER2_IP` | Kafka broker 2 IP | `192.168.1.102` |
| `KAFKA_CLUSTER_ID` | Generated cluster ID | (from generate script) |
| `KAFKA_USERNAME` | Kafka SASL username | `admin` |
| `KAFKA_PASSWORD` | Kafka SASL password | (change from default) |
| `CASSANDRA_SEEDS` | Comma-separated Cassandra IPs | `192.168.1.101,192.168.1.102` |
| `CASSANDRA_BROADCAST_ADDRESS1` | Cassandra node 1 broadcast IP | `192.168.1.101` |
| `CASSANDRA_BROADCAST_ADDRESS2` | Cassandra node 2 broadcast IP | `192.168.1.102` |

---

## **Kubernetes Deployment (k3s)**

Bootstrap scripts install all prerequisites and deploy Cenotoo on a k3s cluster. Run them in order:

```bash
./scripts/01-install-k3s.sh              # k3s + Helm
./scripts/02-install-cert-manager.sh     # cert-manager (required by K8ssandra)
./scripts/03-install-strimzi-operator.sh # Strimzi Kafka operator
./scripts/04-install-k8ssandra-operator.sh # K8ssandra Cassandra operator
./scripts/05-install-flink-operator.sh   # Flink Kubernetes operator
./scripts/06-install-monitoring.sh       # kube-prometheus-stack (optional)
./scripts/07-deploy-cenotoo.sh           # Deploy Cenotoo Helm chart
```

Each script is idempotent (safe to re-run) and waits for readiness before completing.
Version overrides are supported via environment variables (e.g., `STRIMZI_VERSION=0.51.0`).

### Manual Helm install (existing cluster)

```bash
helm install cenotoo deploy/helm/cenotoo/
helm install cenotoo deploy/helm/cenotoo/ -f deploy/helm/cenotoo/values-production.yaml
helm install cenotoo deploy/helm/cenotoo/ -f deploy/helm/cenotoo/values-staging.yaml
```

See `values.yaml` for all configurable parameters including monitoring, backup, and resource limits.

---

## **Initializing Cassandra**

The schema uses `NetworkTopologyStrategy` (recommended even for single-DC deployments):

```bash
pip install -r requirements.txt

# Optional: configure datacenter name and replication factor
export CASSANDRA_DC=datacenter1   # default
export CASSANDRA_RF=2             # default

python cassandra/create_cassandra_tables.py
```

---

## **Development**

```bash
# Lint and format check
ruff check . && ruff format --check .

# Run tests
pytest tests/ -v

# Full CI check (lint + typecheck + test)
ruff check . && ruff format --check . && pytest tests/ -v
```

---

## **Additional Notes**

1. **Kafka uses KRaft mode** — no ZooKeeper dependency. Cluster ID must be generated once and shared across all brokers.

2. **Cassandra auth is enabled** — default credentials are `cassandra/cassandra`. Change after first boot.

3. **Flink in Docker Compose has no HA** — single JobManager for dev/test. Production uses K8s-native HA via the Flink Operator.

4. **Health checks** — all Docker Compose services include health checks. Use `docker ps` to verify all are `(healthy)`.

5. **Consumers** — `kafka-to-cassandra` bridges Kafka topics to Cassandra tables. `kafka-live-consumer` streams messages to stdout for debugging.
