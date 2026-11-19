# Cenotoo Example Notebooks (SDK-first)

Small-to-medium bootstrapping notebooks. REST via `nostradamus-ioto-sdk`; transports via `paho-mqtt` / `aiocoap`.
Notebooks 08 and 09 are the end-to-end transport walkthroughs; notebook 07 is the plain-`requests` REST walkthrough (no SDK).

| # | Notebook | Covers |
|---|----------|--------|
| 01 | `01_rest_setup_projects_collections.ipynb` | Auth, org guard, project + collection CRUD, 404 negative |
| 02 | `02_api_keys_data_lifecycle.ipynb` | Keys lifecycle, raw-key auth, send/get/statistics/delete + vanish |
| 03 | `03_mqtt_ingestion.ipynb` | MQTT QoS 1 publish `{org}/{project}/{collection}` + SDK verify |
| 04 | `04_coap_ingestion.ipynb` | CoAP `POST /{org}/{project}/{collection}?key=` + SDK verify |
| 05 | `05_flink_aggregation_pipeline.ipynb` | avg(temperature) 1-min tumbling window + DELETE 404 proof |
| 06 | `06_async_client_smoke.ipynb` | Async client parity + no-leakage audit |
| 07 | `07_rest_api_plain_http_soil_demo.ipynb` | Plain-`requests` REST walkthrough (JWT + API keys): project/keys/collection, send, filters, stats, delete |
| 08 | `08_rest_sdk_ingest_aggregate_retrieve.ipynb` | **REST end-to-end, SDK only**: provision + scoped keys, batch ingest, filtered retrieval, avg/max/count/p95/distinct aggregation, delete, cleanup |
| 09 | `09_mqtt_ingest_simple_readback.ipynb` | **MQTT end-to-end (simple)**: QoS 1 publish + small batch, SDK read-back, 1-minute aggregation, cleanup |

## Setup

```bash
pip install -r examples/notebooks/requirements.txt
cp examples/notebooks/env.example .env   # fill CENOTOO_USERNAME / CENOTOO_PASSWORD
```

### Exposed TLS interfaces (current deployment)

| Service | URL |
|---|---|
| REST API | `https://api.cenotoo.local` |
| Dashboard | `https://dashboard.cenotoo.local` |
| MQTT | `mqtts://mqtt.cenotoo.local:8883` |

The notebooks default to these hosts; no port-forward is needed. Ensure DNS (or
`/etc/hosts`) resolves the three names to the ingress IP:

```
172.16.63.190 api.cenotoo.local dashboard.cenotoo.local mqtt.cenotoo.local
```

For the self-signed local deployment, point `CENOTOO_CA_BUNDLE` / `MQTT_CA_CERT`
at `cenotoo-local-ca.crt` (the notebooks also auto-detect it in the repo root and
two directories up). The root `.env` exports `SSL_CERT_FILE` and
`REQUESTS_CA_BUNDLE` so the SDK and plain-`requests` notebooks trust the same CA.
For public ACME/Let's Encrypt certificates, leave the CA variables unset.

Run order 01 → 09 (`Kernel → Restart & Run All` each). Notebook 07 is the only
plain-`requests` example (no SDK); notebook 08 is the same REST surface using
**only** `nostradamus-ioto-sdk`; notebook 09 keeps MQTT to publish + SDK read-back.
Both 03 and 09 default to `mqtts://mqtt.cenotoo.local:8883` with TLS verification.

## Skip behavior (never fail on env gaps)

| Situation | Behavior |
|-----------|----------|
| No `CENOTOO_BASE_URL/USERNAME/PASSWORD` | Print SKIP, stop |
| Missing `nostradamus` org (404) | Skip, don't fail |
| No Flink Gateway (503) | Notebook 05 skips |
| Per-key stats 500 | Skip that cell (known server GROUP BY issue) |

Every notebook deletes what it creates (jobs → collection → project). Notebook 06 audits zero leftovers.

`examples/mqtt/` is untouched — the script-based MQTT examples remain canonical for shell/CI use.
