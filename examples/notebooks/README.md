# Cenotoo Example Notebooks (SDK-first)

Small-to-medium bootstrapping notebooks. REST via `nostradamus-ioto-sdk`; transports via `paho-mqtt` / `aiocoap`.

| # | Notebook | Covers |
|---|----------|--------|
| 01 | `01_rest_setup_projects_collections.ipynb` | Auth, org guard, project + collection CRUD, 404 negative |
| 02 | `02_api_keys_data_lifecycle.ipynb` | Keys lifecycle, raw-key auth, send/get/statistics/delete + vanish |
| 03 | `03_mqtt_ingestion.ipynb` | MQTT QoS 1 publish `{org}/{project}/{collection}` + SDK verify |
| 04 | `04_coap_ingestion.ipynb` | CoAP `POST /{org}/{project}/{collection}?key=` + SDK verify |
| 05 | `05_flink_aggregation_pipeline.ipynb` | avg(temperature) 1-min tumbling window + DELETE 404 proof |
| 06 | `06_async_client_smoke.ipynb` | Async client parity + no-leakage audit |

## Setup

```bash
pip install -r examples/notebooks/requirements.txt
cp examples/notebooks/env.example .env   # fill CENOTOO_USERNAME / CENOTOO_PASSWORD
```

Port-forwards when running against k3s:

```bash
kubectl port-forward svc/cenotoo-api 8000:8000 -n cenotoo &
kubectl port-forward svc/cenotoo-mosquitto 1883:1883 -n cenotoo &
# CoAP bridge UDP 5683 (see deploy/k8s/10-coap/)
```

Run order 01 → 06 (`Kernel → Restart & Run All` each).

## Skip behavior (never fail on env gaps)

| Situation | Behavior |
|-----------|----------|
| No `CENOTOO_BASE_URL/USERNAME/PASSWORD` | Print SKIP, stop |
| Missing `nostradamus` org (404) | Skip, don't fail |
| No Flink Gateway (503) | Notebook 05 skips |
| Per-key stats 500 | Skip that cell (known server GROUP BY issue) |

Every notebook deletes what it creates (jobs → collection → project). Notebook 06 audits zero leftovers.

`examples/mqtt/` is untouched — the script-based MQTT examples remain canonical for shell/CI use.
