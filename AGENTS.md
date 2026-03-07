# PROJECT KNOWLEDGE BASE

**Generated:** 2026-03-07
**Commit:** e5212ce
**Branch:** main

## OVERVIEW

ECO-READY Infrastructure — distributed data streaming platform (Kafka + Cassandra + Flink + ksqlDB) orchestrated via Docker Compose, designed for **two-node** HA deployment. Python consumers bridge Kafka→Cassandra. No application framework; pure infrastructure-as-code with utility scripts.

## STRUCTURE

```
centoo/
├── docker-compose.yaml        # All services: kafka×2, cassandra×2, flink×4, zoo×3, ksqldb×2
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
│   └── Dockerfile              # flink:1.18.1 + PyFlink 1.18.1 + SQL Kafka connector JAR
├── cassandra/
│   └── create_cassandra_tables.py  # Schema init: metadata keyspace + 5 tables
└── scripts/
    ├── build-images.sh         # Builds 3 Docker images (flink, kafka-to-cassandra, kafka-live-consumer)
    └── generate-cluster-id.py  # UUID→base64 Kafka cluster ID generator
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add/modify a service | `docker-compose.yaml` | All 14 services defined here |
| Change Cassandra schema | `cassandra/create_cassandra_tables.py` | Run on ONE node only |
| Modify Kafka auth | `kafka/kafka.jaas.conf` | Creds via `$KAFKA_USERNAME`, `$KAFKA_PASSWORD` env vars |
| Change consumer logic | `kafka-to-cassandra/consumer.py` or `kafka-live-consumer/consumer.py` | Each is self-contained |
| Add new Docker image | `scripts/build-images.sh` | Add new build block + create `<service>/Dockerfile` |
| Configure node IPs | `.env` (from `.env.example`) | Different per node; see README for Node 1 vs Node 2 examples |
| Generate cluster ID | `scripts/generate-cluster-id.py` | Run once, copy ID to both nodes' `.env` |

## CONVENTIONS

- **Topic naming**: `{org}.{project}.{collection}` (see consumer.py files)
- **Cassandra table naming**: `{project}_{collection}` within org-named keyspace
- **Consumer group IDs**: `{topic}_cassandra_writer` (kafka-to-cassandra), `{project}.{collection}_live_group` (live consumer)
- **Docker image tags**: hardcoded in `build-images.sh` — `custom-flink-image`, `kafka-cassandra-consumer`, `kafka-live-consumer`
- **Environment-driven config**: All IPs, ports, credentials passed via env vars — never hardcoded
- **Python style**: No packages/modules (`__init__.py`), no type hints — consumers use `logging` module, init script uses `print()`
- **Replication factor**: 2 everywhere (Kafka offsets, transactions, Cassandra keyspace)

## ANTI-PATTERNS (THIS PROJECT)

- **No tests** — zero test files, no test framework configured
- **No CI/CD** — no GitHub Actions, GitLab CI, or similar
- **No linter/formatter** — no `.eslintrc`, `pyproject.toml`, `.editorconfig`
- **ksqlDB licensed under CCL** — cannot be included in a commercial product without Confluent agreement; planned for removal (replace with Flink SQL)

## COMMANDS

```bash
# Generate Kafka cluster ID (run once)
python scripts/generate-cluster-id.py

# Build all Docker images
bash scripts/build-images.sh

# Node 1: start services
docker-compose up -d kafka1 cassandra1 jobmanager1 taskmanager1 zoo1 ksqldb-server1

# Node 2: start services
docker-compose up -d kafka2 cassandra2 jobmanager2 taskmanager2 zoo2 zoo3 ksqldb-server2

# Init Cassandra schema (one node only, after Cassandra is healthy)
pip install -r requirements.txt
python cassandra/create_cassandra_tables.py
```

## NOTES

- Two-node deployment: each node runs a subset of services. `.env` must be customized per node.
- Kafka uses KRaft mode (no external ZooKeeper for Kafka itself) — ZooKeeper is only for Flink HA.
- `docker-compose.yaml` uses `version: "3.5"` — deprecated in modern Docker Compose.
- The `recovery` volume is a bind mount to `./recovery` — directory must exist before starting Flink.
- Cassandra auth is now enabled (`PasswordAuthenticator`) — default creds `cassandra/cassandra`, must be changed after first boot.
- Consumers now use structured logging, graceful SIGTERM shutdown, and validated CQL identifiers.
- `kafka-to-cassandra` uses manual offset commits — only commits after successful Cassandra write.
