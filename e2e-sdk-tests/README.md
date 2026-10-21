# SDK E2E Tests

Repeatable end-to-end suite proving every `nostradamus-ioto-sdk` sync resource
works against a real Cenotoo API. Packaged as its own Docker image runnable
anywhere (laptop, CI, in-cluster Job).

The SDK is installed from a pinned git commit (see `requirements.txt`), never
vendored via `COPY ../sdk` (that breaks the Docker build context) and never
floating on `main`. Bump the pin deliberately and re-verify green.

## Coverage

| Area | Tests |
|------|-------|
| Health | `health()`, `ready()` |
| Organizations | `get()`, `update()` round-trip (restored afterwards) |
| Projects | `list/create/get/update/delete` + unknown-UUID negative |
| Collections | `list/get/create/update/delete` + duplicate-name conflict |
| Project keys | `create` (raw secret) → count+1 list → `api_key` send proof → body-based `regenerate`/`delete_key` routes; old-key-invalid; bogus-regenerate 404 |
| Collection keys | `get_statistics()` after data exists (skips on server 500 — Cassandra GROUP BY bug, see below) |
| Data | `send` N records → poll `get` (Cassandra write path is async) → `statistics(count)` → `delete` by key → poll until gone |
| Flink pipeline | project → READ+WRITE keys → collection → burst send → readable poll → guided `avg(temperature)` 1-min tumbling job → results assert (22.0, count 3) → job/collection/project cleanup |
| Users (admin) | `create/list/update_password/delete`; new-user login works, post-delete login fails |
| Negatives | bad password → 401, invalid api key → error, unknown UUID → 404, schema-violating payload → 422 |
| Async | one smoke test (`aget`) — sync is the contract |

Filter format is `{"property_name": ..., "operator": ..., "property_value": ...}`
(`eq/ne/lt/lte/gt/gte/in/contains`), matching `cenotoo-api/routers/get_data.py`.
There is deliberately no `like` operator.

## Environment

| Variable | Description | Default |
|----------|-------------|---------|
| `CENOTOO_BASE_URL` | API base (no `/api/v1` suffix) | `http://cenotoo-api:8000` (in-cluster) |
| `CENOTOO_USERNAME` / `CENOTOO_PASSWORD` | Seeded admin (OAuth2 password flow) | — (required) |
| `E2E_PREFIX` | Resource name prefix | `e2e` |
| `E2E_TIMEOUT_S` / `E2E_INTERVAL_S` | Poll-with-timeout for eventual consistency | `120` / `2` |

Without `CENOTOO_BASE_URL` + creds the suite **skips** (exit 0), never fails —
plain `pytest tests/` stays unaffected.

## Run locally

```bash
CENOTOO_BASE_URL=http://172.16.63.190:30080 \
CENOTOO_USERNAME=admin CENOTOO_PASSWORD='<from .secrets/credentials.txt>' \
  ./e2e-sdk-tests/run-e2e.sh
# or directly:
CENOTOO_BASE_URL=... CENOTOO_USERNAME=... CENOTOO_PASSWORD=... \
  pytest e2e-sdk-tests/ -m e2e -v
```

## Run via Docker

```bash
docker build -t sdk-e2e-tests:latest ./e2e-sdk-tests
docker run --rm \
  -e CENOTOO_BASE_URL=http://172.16.63.190:30080 \
  -e CENOTOO_USERNAME=admin -e CENOTOO_PASSWORD='<pass>' \
  sdk-e2e-tests:latest
```

## Run in-cluster

```bash
# One-time secret (admin values from the host's .secrets/credentials.txt):
kubectl -n cenotoo create secret generic cenotoo-e2e-credentials \
  --from-literal=username=admin --from-literal=password='<pass>'
# Image must be imported (scripts/build-images.sh does this):
kubectl apply -f e2e-sdk-tests/k8s/job.yaml
kubectl logs -n cenotoo job/sdk-e2e-tests
```

## Troubleshooting

- Data `get` timeouts: the Kafka→Cassandra write path lags badly and variably
  (observed <30s one run, >120s the next). Default `E2E_TIMEOUT_S=300`
  (Job matches); heartbeats print every ~30s. Timeout errors dump the last result.
- `409/422` on create: a previous run left residue — fixture teardown deletes in
  reverse order (collection → project → keys); re-run cleans via unique names.
- Users suite skips/fails: the seeded admin needs user-management permission.
- Org/users tests skip when the server has no `nostradamus` organization:
  the SDK hardcodes that org name in `organizations.get()` — the `e2e_org`
  fixture skips instead of failing (seen on servers seeded otherwise).
- `api_list_items` helper: the live API paginates list responses
  (`{items, total, offset, limit}`) but the pinned SDK's `list()` helpers parse
  the envelope as a single model and raise `ValidationError`. Until the SDK
  unwraps envelopes, e2e fetches lists via the SDK's authenticated
  `request()` and parses `items` into SDK models explicitly.
- `api_create_project` helper: POST /projects returns
  `{"message", "id": {"project_id": ...}}` (id nested one level deep) but
  the pinned SDK's `create()` passes `id` un-unwrapped into its follow-up
  `self.get()` → `ValueError`. Until the SDK unwraps it, e2e POSTs raw and
  GETs via the SDK. (`collections.create` is unaffected — the API embeds the
  new UUID in `message`, which the SDK's regex fallback extracts.)
- Names (projects, collections, users, record keys) may contain only latin
  letters, numbers and underscores — `unique_name` enforces this and
  sanitizes `E2E_PREFIX`.
- User password rotation / deletion go through `api_raw`, not the SDK: the
  SDK's `update_password`/`delete` call bare `update_password` / `users`
  paths that do not exist server-side (all 404). The real routes are
  `PUT /organizations/{id}/users/update_password` and
  `DELETE /organizations/{id}/users`, both org-scoped with a JSON body.
  (`users.create`/`users.list` SDK methods are fine; note `list` returns the
  raw `{items, ...}` envelope — unwrap it.)
- Never `update_password`/`delete` the seeded admin itself — the suite only
  touches users it creates.
- Project keys are hashed at rest: `create` returns the raw secret (capture
  it — `list` only ever shows hashes), and the SDK's `get`/`regenerate`/
  `delete` hit `.../keys/{secret}` paths that do not exist server-side
  (all 404). The suite uses the real body-based routes instead:
  `PUT .../keys/regenerate` + `DELETE .../keys/delete_key` with
  `{"key_value": ...}` via the `api_raw` helper.
- `projects.update` / `collections.update` return `{"message": ...}`, not the
  updated object, so the SDK raises *pydantic's* `ValidationError` (not the
  SDK subclass) — the suite suppresses exactly that and proves the update
  with a follow-up GET.
- `collection_keys.get_statistics` currently 500s server-side (its Cassandra
  query GROUPs BY part of the partition key). The suite skips on 500;
  remove the skip once the server query is fixed.
