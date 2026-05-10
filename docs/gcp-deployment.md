# Cenotoo on GCP — Deploying a Public Instance

This guide walks you from a freshly created **Google Cloud Compute Engine VM** to a public, internet-reachable Cenotoo instance using the new interactive installer (`scripts/install.sh`).

Target audience: someone who already has a Cenotoo checkout on a GCP VM and wants the shortest correct path to a working public deployment.

---

## 1. Provision the GCP VM

### Recommended specs

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Machine type | `e2-standard-2` (2 vCPU, 8 GB) | `e2-standard-4` (4 vCPU, 16 GB) |
| Boot disk    | 50 GB SSD                       | 100 GB SSD                       |
| OS image     | Ubuntu 22.04 LTS                | Ubuntu 24.04 LTS                 |
| Network tag  | `cenotoo`                       | `cenotoo`                        |

```bash
gcloud compute instances create cenotoo-1 \
  --zone=us-central1-a \
  --machine-type=e2-standard-4 \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --boot-disk-size=100GB --boot-disk-type=pd-ssd \
  --tags=cenotoo
```

### Reserve a static external IP (strongly recommended)

A static IP is required for any DNS-based setup (Let's Encrypt, ingress, etc.).

```bash
gcloud compute addresses create cenotoo-ip --region=us-central1
gcloud compute instances delete-access-config cenotoo-1 --zone=us-central1-a
gcloud compute instances add-access-config cenotoo-1 --zone=us-central1-a \
  --address=$(gcloud compute addresses describe cenotoo-ip --region=us-central1 --format='value(address)')
```

### Open the GCP firewall

You must explicitly allow the ports Cenotoo exposes. The installer can configure `ufw` on the VM, but **GCP's perimeter firewall must be opened separately**.

```bash
# Always: API + dashboard
gcloud compute firewall-rules create cenotoo-http \
  --direction=INGRESS --action=ALLOW \
  --rules=tcp:80,tcp:443,tcp:30080,tcp:30081 \
  --target-tags=cenotoo --source-ranges=0.0.0.0/0

# If using MQTT
gcloud compute firewall-rules create cenotoo-mqtt \
  --direction=INGRESS --action=ALLOW \
  --rules=tcp:1883 \
  --target-tags=cenotoo --source-ranges=0.0.0.0/0

# If using CoAP (UDP)
gcloud compute firewall-rules create cenotoo-coap \
  --direction=INGRESS --action=ALLOW \
  --rules=udp:30683 \
  --target-tags=cenotoo --source-ranges=0.0.0.0/0
```

| Port  | Proto | Purpose                          | When to open                     |
|------:|:-----:|----------------------------------|----------------------------------|
| 22    | TCP   | SSH                              | Always (lock down to your IP)    |
| 80    | TCP   | HTTP / Let's Encrypt HTTP-01     | If using domain + TLS            |
| 443   | TCP   | HTTPS                            | If using domain + TLS            |
| 30080 | TCP   | Cenotoo API (NodePort)           | If exposing API via NodePort     |
| 30081 | TCP   | Dashboard (NodePort)             | If installing the dashboard      |
| 1883  | TCP   | MQTT broker                      | If installing MQTT bridge        |
| 30683 | UDP   | CoAP bridge                      | If installing CoAP bridge        |

For TLS via Let's Encrypt's HTTP-01 challenge, **port 80 must be reachable from the internet** during certificate issuance.

### Point your DNS records (optional, required for TLS)

Add an `A` record for your domain pointing to the VM's external IP. Verify before running the installer:

```bash
dig +short api.example.com
# → 34.123.45.67   (must match VM external IP)
```

---

## 2. SSH into the VM and clone Cenotoo

```bash
gcloud compute ssh cenotoo-1 --zone=us-central1-a

# On the VM:
sudo apt-get update && sudo apt-get install -y git curl
git clone https://github.com/<your-org>/cenotoo.git
cd cenotoo

# (Optional) clone companion repos next to it for API + dashboard
git clone https://github.com/robotics-4-all/cenotoo-api.git ../cenotoo-api
git clone https://github.com/robotics-4-all/cenotoo-dashboard.git ../cenotoo-dashboard
```

---

## 3. Run the interactive installer

```bash
sudo ./scripts/install.sh
```

The installer is a guided wrapper around the existing `01-` … `24-` numbered scripts. It will:

1. **Preflight** — check OS (Ubuntu), CPU, RAM, disk, sudo, and required tooling.
2. **Ask configuration questions** — exposure model, domain, TLS, secrets, optional bridges, monitoring.
3. **Generate a plan** — show you exactly what will be installed, then ask for confirmation.
4. **Run installation** — execute the chosen `0X-*.sh` scripts in order, with live progress.
5. **Save artifacts** — write your generated credentials to `./.secrets/credentials.txt` (chmod 600).
6. **Print next steps** — show the URLs you can hit, how to log in, and where to find logs.

### Configuration prompts you will see

| Prompt | Notes |
|--------|-------|
| **Exposure model** | `nodeport` (open ports on the VM) or `ingress-tls` (Traefik + cert-manager + Let's Encrypt). |
| **Domain** | Required for `ingress-tls`. Leave empty for `nodeport`. |
| **Let's Encrypt email** | Required for `ingress-tls`. |
| **Admin password / Cassandra / Postgres / JWT / API-key secrets** | Press **Enter** to auto-generate, or paste your own. |
| **Install monitoring stack?** | Prometheus + Grafana — adds ~2 GB RAM. Default yes. |
| **Install MQTT bridge?** | Default yes. |
| **Install CoAP bridge?** | Default yes. |
| **Install dashboard?** | Requires `../cenotoo-dashboard` checkout. Default yes if present. |
| **Install Flink jobs?** | Stream processing. Default yes. |

### Re-running

The installer is **idempotent**. Re-run it any time — finished steps detect their existing state and skip work.

```bash
sudo ./scripts/install.sh                     # full guided flow
sudo ./scripts/install.sh --plan-only         # show plan, exit without installing
sudo ./scripts/install.sh --resume            # skip prompts, use saved config
sudo ./scripts/install.sh --uninstall         # remove Cenotoo (k3s itself stays)
```

---

## 4. Verify

After the installer finishes you will see a summary box. Quick checks:

```bash
# Cluster + pods
kubectl get pods -n cenotoo

# API health
NODE_IP=$(curl -s ifconfig.me)
curl http://$NODE_IP:30080/health
# → {"status":"ok"}

# With TLS
curl https://api.example.com/health
```

The credentials file is at `./.secrets/credentials.txt`. **Save it somewhere safe and delete the local copy when you're done.**

---

## 5. Production hardening checklist

The installer gets you running. These are things you should do before treating the deployment as production:

- [ ] **Restrict SSH** to your office / home IPs in the GCP firewall (`gcloud compute firewall-rules update default-allow-ssh --source-ranges=…`).
- [ ] **Rotate the admin password** after first login (`PUT /users/me/password`).
- [ ] **Move credentials off the VM** — copy `./.secrets/credentials.txt` to your password manager and delete the file.
- [ ] **Snapshot the boot disk** — `gcloud compute disks snapshot cenotoo-1 --zone=us-central1-a`.
- [ ] **Enable Cassandra backups** with [Medusa](https://docs.k8ssandra.io/components/medusa/) if running long-term.
- [ ] **Lock down NodePorts** — if you used `ingress-tls`, close 30080/30081 in the GCP firewall (only 80/443 should be open).
- [ ] **Configure log retention** — `journalctl --vacuum-time=14d` on the VM.
- [ ] **Set up monitoring alerts** — point Grafana to Slack/PagerDuty via the bundled Alertmanager.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `kubectl: command not found` after install | Shell hasn't picked up new `KUBECONFIG` | `exec bash` or open a new SSH session |
| API pod CrashLoopBackOff | Cassandra or Postgres not ready yet | `kubectl logs -n cenotoo deploy/cenotoo-api --previous`; usually resolves after 1–2 min |
| Let's Encrypt certificate stuck `Pending` | Port 80 not open in GCP, or DNS not propagated | Verify both, then `kubectl delete certificaterequest -n cenotoo --all` |
| `sudo k3s ctr` errors during image build | k3s service not running | `sudo systemctl status k3s` |
| Out of memory after install | VM too small (≤ 4 GB) | Skip monitoring (`--without-monitoring`) or upgrade to e2-standard-4 |
| `mqtt-bridge` ImagePullBackOff | Image not built locally | `bash scripts/build-images.sh` |

For deeper issues see the original [k3s deployment guide](k3s-setup.md), which documents every step the installer runs.
