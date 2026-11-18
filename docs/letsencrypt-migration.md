# Migrating to Let's Encrypt (with automatic renewal)

This note covers moving a running Cenotoo deployment from **self-signed
certificates** (or legacy per-host NodePort TLS) to a real **Let's Encrypt**
certificate issued by cert-manager, and how renewal works afterwards.

It assumes the current repo state: a single shared `Certificate
cenotoo-public-tls` covering `api`, `dashboard` and `mqtt`, a cluster-wide
`ClusterIssuer cenotoo-letsencrypt` (HTTP-01 via Traefik), and one
`TLSStore/default` pointing at the shared secret.

TL;DR — once DNS and port 80 are live, this is the whole migration:

```bash
# 1. point the config at production ACME
scripts/set-domain.sh --domain example.com --email ops@example.com
# 2. apply (cert-manager issues + renews forever)
sudo ./scripts/09-expose-api.sh --non-interactive
# 3. prove it
curl -I https://api.example.com/health
```

---

## 1. Prerequisites

| Requirement | Why | How to check |
|---|---|---|
| Three DNS A records — `api.`, `dashboard.`, `mqtt.` `<base-domain>` — pointing at the node's public IP | HTTP-01 validates each SAN by name | `dig +short api.example.com` → node IP |
| Port **80/tcp** reachable from the internet | ACME HTTP-01 challenge **and every renewal** | `curl -I http://api.example.com/` from outside |
| Port **443/tcp** open | Served traffic (already required) | — |
| Port **8883/tcp** open | MQTT over TLS | — |
| A real contact address | ACME account registration | `CENOTOO_TLS_EMAIL` |
| cert-manager healthy | Issues and rotates the cert | `kubectl -n cert-manager get pods` |
| Traefik ≥ v3.2 with the `mqtts` entrypoint | See `deploy/k8s/00-traefik/helmchartconfig.yaml` | `kubectl -n kube-system get svc traefik -o yaml \| grep -A2 mqtts` |

Let's Encrypt **never issues for a bare IP address** — a public DNS name is
mandatory. If you are still IP-only, see §7 (staging on a temporary domain) or
stay on `--self-signed`.

### Firewall reminder

Port 80 is not "only for first issuance". The renewal challenge is served over
plain HTTP through `allowACMEByPass` (which is why the `web → websecure`
redirect preserves `/.well-known/acme-challenge/*`). **If port 80 is closed
after issuance, the certificate will silently fail to renew and the site will
break at expiry** (~90 days later).

---

## 2. Test on staging first (recommended)

Let's Encrypt production has hard rate limits (5 duplicate certificates per
week per exact SAN set, 50 per registered domain per week). Use staging until
issuance succeeds:

```bash
scripts/set-domain.sh --show            # confirm derived hosts + DNS checklist

# switch the ACME directory to staging
sed -i 's|^CENOTOO_ACME_SERVER=.*|CENOTOO_ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory|' \
  deploy/k8s/cenotoo.env

sudo ./scripts/09-expose-api.sh --non-interactive
```

Staging certificates are **not trusted by browsers or clients** — that is
expected. The point is that `Certificate/cenotoo-public-tls` reaches
`Ready=True`, which proves DNS and port 80 are correct.

Check:

```bash
kubectl -n cenotoo get certificate cenotoo-public-tls -o wide
kubectl -n cenotoo describe certificate cenotoo-public-tls
kubectl -n cenotoo get order,challenge
```

---

## 3. Switch to production

```bash
sed -i 's|^CENOTOO_ACME_SERVER=.*|CENOTOO_ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory|' \
  deploy/k8s/cenotoo.env

sudo ./scripts/09-expose-api.sh --non-interactive
```

or, equivalently, through the CLI wrapper which persists the domain and then
applies:

```bash
scripts/set-domain.sh --domain example.com --email ops@example.com --apply
```

What the script does, in order (idempotent — re-running is safe):

1. Applies `HelmChartConfig/traefik` (entrypoints + ACME bypass + redirect).
2. Applies `ClusterIssuer/cenotoo-letsencrypt` with the production directory.
3. Applies `TLSStore/default` in the `cenotoo` namespace.
4. Applies `Certificate/cenotoo-public-tls` (SANs: api, dashboard, mqtt).
5. Applies both `Ingress` objects and the `IngressRouteTCP` for MQTT.
6. Waits up to 300s for `Certificate` `Ready=True`, then runs the legacy
   cleanup (deletes `cenotoo-api-tls` / `cenotoo-dashboard-tls` secrets and
   certificates, strips old `cert-manager.io/cluster-issuer` annotations).

### Verify

```bash
# chain + SANs, straight from the node
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates -ext subjectAltName

# endpoints
curl -sS -o /dev/null -w '%{http_code}\n' https://api.example.com/health
curl -sS -o /dev/null -w '%{http_code}\n' https://api.example.com/docs
curl -sS -o /dev/null -w '%{http_code}\n' https://dashboard.example.com/

# plain HTTP must redirect, and must still serve ACME challenges
curl -sSI http://api.example.com/ | head -3          # expect 301/308 -> https

# MQTT over TLS
mosquitto_pub -h mqtt.example.com -p 8883 --cafile /etc/ssl/certs/ca-certificates.crt \
  -t test -m hello -d

# end-to-end from outside the cluster
CENOTOO_NODE_IP=<node-ip> CENOTOO_ADMIN_PASSWORD=<pass> \
  ./scripts/26-test-remote-tls.sh --with-e2e
```

The issuer must be `Let's Encrypt` (`O = Let's Encrypt`, `CN = R10/R11/...`),
**not** `CN = <your-ip>` — that would mean Traefik is still serving the
self-signed secret.

---

## 4. Automatic renewal

Nothing to schedule. cert-manager owns the lifecycle:

- A Let's Encrypt certificate lives **90 days**.
- cert-manager renews at **2/3 of lifetime ≈ 30 days before expiry**
  (`renewBefore` default), then re-issues and updates the secret in place.
- `rotationPolicy: Always` (set in `certificate.yaml.tpl`) rotates the private
  key on each renewal.
- Traefik picks the new material from the same secret **without a restart**,
  because every router references `secretName: cenotoo-public-tls` and
  `TLSStore/default` points at the same secret.

Verify renewal is wired correctly:

```bash
kubectl -n cenotoo get certificate cenotoo-public-tls \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
# expect Ready=True, Issuing absent/false

kubectl -n cenotoo get certificaterequest,order,challenge
# expect no stuck Pending objects

kubectl -n cert-manager logs deploy/cert-manager --tail=50 | grep -i renew
```

A dry-run renewal can be forced at any time:

```bash
kubectl -n cenotoo delete secret cenotoo-public-tls
# cert-manager sees the missing secret and re-issues within ~1 minute
kubectl -n cenotoo get certificate cenotoo-public-tls -w
```

(`Certificate` itself stays; only the Secret is recreated. This is the same
mechanism a scheduled renewal uses, so it is a safe test.)

---

## 5. Monitoring (don't discover expiry the hard way)

Expiry is the only failure that is both silent and total. Watch it:

```bash
# quick human check — days remaining
kubectl -n cenotoo get secret cenotoo-public-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -enddate
```

Recommended alert (Prometheus, if `06-install-monitoring.sh` is installed) —
cert-manager exports `certmanager_certificate_expiration_timestamp_seconds`:

```yaml
- alert: CenotooCertificateExpiringSoon
  expr: |
    (certmanager_certificate_expiration_timestamp_seconds{name="cenotoo-public-tls"}
     - time()) < 14 * 86400
  for: 1h
  labels:
    severity: critical
  annotations:
    summary: "Cenotoo TLS certificate expires in under 14 days"
    description: "Renewal has likely failed. Check port 80 reachability and DNS."
```

Also alert on `certmanager_certificate_ready_status{condition="False"} == 1`.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Certificate` stuck `False`, reason `DoesNotExist`/`Pending` | Challenge cannot be reached | Confirm DNS A records and port 80 from **outside**: `curl -I http://api.example.com/` |
| `order`/`challenge` objects `Pending` forever | Old failed attempts cached | `kubectl -n cenotoo delete challenge,order --all` then re-run `09-expose-api.sh` |
| `too many certificates already issued` | Production rate limit | Switch `CENOTOO_ACME_SERVER` to staging until DNS/port issues are fixed |
| Browser shows your old self-signed cert | Self-signed secret still winning | Re-run `09-expose-api.sh`; confirm `kubectl -n cenotoo get certificate cenotoo-public-tls` is `Ready=True` |
| Renewal never happens | Port 80 closed, DNS changed, or cert-manager down | Reopen 80, `kubectl -n cert-manager get pods`, then delete the secret to force re-issue |
| `mqtts://…:8883` handshake fails but HTTPS works | `mqtts` entrypoint missing | Re-apply `deploy/k8s/00-traefik/helmchartconfig.yaml`, restart Traefik, confirm `8883` in `kubectl -n kube-system get svc traefik` |
| Certificate `Ready` but Traefik serves default cert | `TLSStore` missing/misnamed | `kubectl -n cenotoo get tlsstore default -o yaml` → `secretName: cenotoo-public-tls` |

Diagnostics bundle:

```bash
kubectl -n cenotoo describe certificate cenotoo-public-tls
kubectl -n cenotoo get order,challenge -o wide
kubectl -n cert-manager logs deploy/cert-manager --tail=100
kubectl -n kube-system logs deploy/traefik --tail=50
```

---

## 7. Special cases

### Coming from self-signed mode

Self-signed runs leave behind a local CA that Let's Encrypt mode does not use.
After the ACME certificate is `Ready=True`:

```bash
# optional: remove the now-unused local CA material
kubectl -n cenotoo delete secret cenotoo-public-ca --ignore-not-found
rm -rf deploy/k8s/.local-ca
```

Clients that trusted `cenotoo-local-ca.crt` must switch to the public trust
store — no `--cacert` / `--cafile` / `SSL_CERT_FILE` override any more:

```bash
curl https://api.example.com/health                    # no --cacert
mosquitto_pub -h mqtt.example.com -p 8883 \
  --cafile /etc/ssl/certs/ca-certificates.crt -t test -m hi
```

SDK users: unset `CENOTOO_CA_BUNDLE` / `SSL_CERT_FILE`.

### No public domain yet (temporary domain for staging)

If the VM has only an IP but the deployment must be validated end to end over
real TLS, use a wildcard DNS service such as `sslip.io` — `<ip>.sslip.io`
resolves to that IP with no DNS setup:

```bash
scripts/set-domain.sh --domain 203.0.113.10.sslip.io --email ops@example.com --apply
```

Keep it on staging ACME, because production issuance for a throwaway name
burns rate limit. Switch to the real domain later with `set-domain.sh` +
`09-expose-api.sh` — the Certificate updates in place and cert-manager
re-issues for the new SANs.

### k3s upgrade

The `HelmChartConfig` that adds the `mqtts` entrypoint is reapplied by
helm-controller, but if Traefik is upgraded past a major version, re-apply
`deploy/k8s/00-traefik/helmchartconfig.yaml` and confirm:

```bash
kubectl -n kube-system get svc traefik -o yaml | grep -A2 mqtts
```

---

## 8. Rollback

To go back to certificates with no ACME dependency:

```bash
sudo ./scripts/09-expose-api.sh --self-signed --ip <node-ip> --ca-out ./cenotoo-local-ca.crt
```

This does **not** delete the `ClusterIssuer`/`Certificate`; it repoints the
shared secret at a locally minted certificate. Leftover ACME objects are
inert once the secret is replaced, and re-running the ACME path takes over
again cleanly.

Emergency plaintext rollback (unsupported, unencrypted traffic) is available
via `--force-legacy-nodeport` — documented only in the script's `--help`.

---

## 9. Checklist

- [ ] `dig +short api.example.com` / `dashboard.` / `mqtt.` all return the node IP
- [ ] Port 80 reachable from the internet, and staying open permanently
- [ ] Ports 443 and 8883 open; 30080/30081/30683 closed
- [ ] Staging ACME reached `Ready=True`
- [ ] `CENOTOO_ACME_SERVER` switched to production and re-applied
- [ ] `openssl s_client` shows a Let's Encrypt issuer and the 3 SANs
- [ ] `mqtts://mqtt.<base>:8883` publishes successfully
- [ ] `scripts/26-test-remote-tls.sh --with-e2e` passes from an external host
- [ ] Expiry alert (`< 14 days`) configured
- [ ] Self-signed leftovers removed (`cenotoo-public-ca` secret, `.local-ca/`)
