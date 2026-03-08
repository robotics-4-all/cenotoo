# Cenotoo: k3s Deployment Guide

Cenotoo is a distributed data streaming platform (Kafka + Cassandra + Flink) with Python consumers that bridge Kafka to Cassandra. This guide deploys it on a single-node k3s cluster using raw K8s manifests. Final result: 10 pods in the `cenotoo` namespace.

```
┌─────────────────────────────────────────────────────┐
│                   k3s Cluster                       │
│                                                     │
│  ┌──────────┐    ┌───────────┐    ┌──────────────┐ │
│  │  Kafka    │───>│ cassandra │───>│  Cassandra   │ │
│  │ (Strimzi) │    │  -writer  │    │ (StatefulSet)│ │
│  │ 2 brokers │    └───────────┘    └──────────────┘ │
│  │ 3 ctrl    │                                      │
│  │ 1 entity  │    ┌───────────┐    ┌──────────────┐ │
│  │   op      │───>│   live    │    │    Flink     │ │
│  └──────────┘    │ -consumer │    │  (Operator)  │ │
│                   └───────────┘    └──────────────┘ │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

- Linux host (Ubuntu 20.04+ or similar) with systemd
- At least 8GB RAM, 4 CPU cores, 50GB disk (16GB+ RAM recommended)
- Docker installed (for building consumer images)
- curl, git
- Root or sudo access

## Step 1: Clone the Repository

```bash
git clone <repo-url> cenotoo
cd cenotoo
```

## Step 2: Install k3s

```bash
sudo ./scripts/01-install-k3s.sh
```

Installs a single-node k3s cluster, configures kubeconfig at `/etc/rancher/k3s/k3s.yaml`, and installs Helm.

Override the version with `K3S_VERSION=v1.31.0+k3s1 sudo ./scripts/01-install-k3s.sh`.

Verify:

```bash
kubectl get nodes
# NAME     STATUS   ROLES                  AGE   VERSION
# myhost   Ready    control-plane,master   30s   v1.31.x+k3s1
```

## Step 3: Install cert-manager

```bash
sudo ./scripts/02-install-cert-manager.sh
```

Required by the Flink Operator for webhook certificates. Uses `kubectl apply` (not Helm) to avoid ownership conflicts if cert-manager is shared with other projects.

Override: `CERT_MANAGER_VERSION=v1.17.2`

Verify:

```bash
kubectl get pods -n cert-manager
# 3 pods Running
```

## Step 4: Install Strimzi Kafka Operator

```bash
sudo ./scripts/03-install-strimzi-operator.sh
```

Manages Kafka clusters via CRDs (Kafka, KafkaNodePool, KafkaUser). Installed via Helm into the `strimzi` namespace. Watches all namespaces by default.

Override: `STRIMZI_VERSION=0.51.0`

Verify:

```bash
kubectl get pods -n strimzi
# 1 pod Running

kubectl get crd | grep kafka
# kafkas.kafka.strimzi.io, kafkanodepools.kafka.strimzi.io, kafkausers.kafka.strimzi.io, ...
```

## Step 5: Install Flink Operator

```bash
sudo ./scripts/05-install-flink-operator.sh
```

Manages Flink clusters via the FlinkDeployment CRD. Installed via Helm into the `flink` namespace.

There is no script 04. Cassandra is deployed as a raw StatefulSet (no operator).

Override: `FLINK_OPERATOR_VERSION=1.14.0`

Verify:

```bash
kubectl get pods -n flink
# 1-2 pods Running

kubectl get crd | grep flink
# flinkdeployments.flink.apache.org
```

## Step 6: Build and Import Docker Images

```bash
./scripts/build-images.sh --k3s
```

Builds 3 Docker images and imports them into k3s containerd:

| Image | Source |
|-------|--------|
| `custom-flink-image:latest` | `flink/Dockerfile` |
| `kafka-cassandra-consumer:latest` | `kafka-to-cassandra/Dockerfile` |
| `kafka-live-consumer:latest` | `kafka-live-consumer/Dockerfile` |

The `--k3s` flag handles the import via `docker save | sudo k3s ctr images import -`.

Verify:

```bash
sudo k3s ctr images list | grep -E 'custom-flink|kafka-cassandra|kafka-live'
```

## Step 7: Deploy Cenotoo

```bash
sudo ./scripts/07-deploy-cenotoo.sh
```

Applies all K8s manifests in dependency order via `kubectl apply`:

| Order | Manifest | What it creates |
|-------|----------|-----------------|
| 1 | `00-namespace.yaml` | `cenotoo` namespace |
| 2 | `01-secrets/` | Kafka credentials + Cassandra superuser secret |
| 3 | `02-kafka/` | Strimzi Kafka CR (KRaft, 2 brokers, 3 controllers, SCRAM-SHA-512) + KafkaUser with ACLs |
| 4 | `03-cassandra/` | Headless service + StatefulSet (1024M heap, PasswordAuthenticator via init container) |
| 5 | `04-flink/` | ServiceAccount, Role, RoleBinding, PVC, FlinkDeployment CR |
| 6 | `05-consumers/` | cassandra-writer + live-consumer Deployments |
| 7 | `06-monitoring/` | PodMonitors, PrometheusRules, Grafana dashboards (only if Prometheus Operator is installed) |

The script waits for Kafka and Cassandra to be ready before deploying consumers.

Verify:

```bash
sudo kubectl get pods -n cenotoo
```

Expected pods:

| Pod | Count | Managed By |
|-----|-------|------------|
| `cenotoo-kafka-cenotoo-broker-{0,1}` | 2 | Strimzi |
| `cenotoo-kafka-cenotoo-controller-{2,3,4}` | 3 | Strimzi |
| `cenotoo-kafka-entity-operator-*` | 1 (2/2 containers) | Strimzi |
| `cenotoo-cassandra-0` | 1 | StatefulSet |
| `cenotoo-flink-*` | 1 | Flink Operator |
| `cenotoo-cassandra-writer-*` | 1 | Deployment |
| `cenotoo-live-consumer-*` | 1 | Deployment |

## Step 8: Initialize Cassandra Schema

The cassandra-writer consumer dynamically builds INSERT statements from message fields, but the target keyspace and table must exist first.

```bash
sudo kubectl -n cenotoo exec -it cenotoo-cassandra-0 -- cqlsh -u cassandra -p cassandra -e "
  CREATE KEYSPACE IF NOT EXISTS cenotoo
    WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1};
  CREATE TABLE IF NOT EXISTS cenotoo.demo_sensors (
    key TEXT PRIMARY KEY,
    temperature DOUBLE,
    humidity DOUBLE
  );
"
```

For multi-node production deployments, use `NetworkTopologyStrategy` instead of `SimpleStrategy`.

## Step 9: Verify the Deployment

```bash
# Quick health check: pods, CRDs, services, endpoints (16 checks, ~10s)
sudo ./scripts/smoke-test.sh

# Full E2E: Kafka produce/consume with SCRAM auth, Cassandra read/write,
# and the pipeline test: Kafka -> cassandra-writer -> Cassandra (~60s)
sudo ./scripts/integration-test.sh
```

All tests should report PASS.

## Step 10: Install Monitoring (Optional)

```bash
sudo ./scripts/06-install-monitoring.sh
```

Installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager) into the `monitoring` namespace.

After installing, re-run the deploy script to apply Cenotoo monitoring manifests:

```bash
sudo ./scripts/07-deploy-cenotoo.sh
```

Access Grafana:

```bash
sudo kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Default credentials are printed by the install script.

Override: `PROMETHEUS_STACK_VERSION=82.9.0`

## Configuration Reference

### Version Overrides

| Variable | Default | Script |
|----------|---------|--------|
| `K3S_VERSION` | latest stable | `01-install-k3s.sh` |
| `CERT_MANAGER_VERSION` | `v1.17.2` | `02-install-cert-manager.sh` |
| `STRIMZI_VERSION` | `0.51.0` | `03-install-strimzi-operator.sh` |
| `FLINK_OPERATOR_VERSION` | `1.14.0` | `05-install-flink-operator.sh` |
| `PROMETHEUS_STACK_VERSION` | `82.9.0` | `06-install-monitoring.sh` |

### Secrets

| Secret | Default | Location |
|--------|---------|----------|
| Cassandra superuser | `cassandra` / `cassandra` | `deploy/k8s/01-secrets/cassandra-superuser.yaml` |
| Kafka consumer credentials | Auto-generated by Strimzi | Secret `cenotoo-consumer` (created from KafkaUser CR) |

Change the Cassandra superuser password after first boot. Kafka credentials are managed by Strimzi and should not be edited manually.

### Resource Requirements

| Component | Memory | CPU |
|-----------|--------|-----|
| Kafka brokers (x2) | 2-4Gi each | 1-2 cores each |
| Kafka controllers (x3) | 1-2Gi each | 0.5-1 core each |
| Cassandra | 2-4Gi (1024M JVM heap) | 0.5-2 cores |
| Flink | Per FlinkDeployment config | Per FlinkDeployment config |
| Each consumer | 128-512Mi | 0.1-0.5 cores |

## Troubleshooting

**cassandra-writer in CrashLoopBackOff**

Check logs with `kubectl -n cenotoo logs deployment/cenotoo-cassandra-writer --tail=50`. Common causes: Cassandra schema does not exist (run Step 8), Kafka SASL credentials are wrong, or Cassandra auth failure.

**Kafka pods stuck in Pending**

PVCs are not bound. Check with `kubectl get pvc -n cenotoo`. Stale PVCs from a previous deployment may need to be deleted: `kubectl delete pvc -n cenotoo -l strimzi.io/cluster=cenotoo-kafka`.

**Cassandra OOMKilled**

Increase `MAX_HEAP_SIZE` in `deploy/k8s/03-cassandra/statefulset.yaml`. The heap must be less than the container memory limit (default 4Gi limit, 1024M heap).

**ImagePullBackOff**

Images were not imported into k3s. Re-run `./scripts/build-images.sh --k3s`.

**Kafka GROUP_AUTHORIZATION_FAILED**

The consumer is not authenticating with SASL, or the KafkaUser secret does not exist. Verify: `kubectl get secret cenotoo-consumer -n cenotoo`.

**k3s ctr image import fails with "no such file or directory"**

Do not use process substitution `<(docker save ...)` with sudo. Use a pipe instead: `docker save image:tag | sudo k3s ctr images import -`.

## Uninstall

```bash
# Remove Cenotoo (preserves operators)
sudo kubectl delete namespace cenotoo

# Remove PVCs (WARNING: deletes all data)
sudo kubectl delete pvc -n cenotoo --all

# Full teardown (removes everything including k3s)
/usr/local/bin/k3s-uninstall.sh
```
