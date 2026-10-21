"""E2E: full streaming pipeline — project, keys, collection, data,
Flink aggregation, observe, cleanup.

The SDK has no Flink resource, so job lifecycle calls go through the SDK's
authenticated request() as raw REST (same auth, no workaround — there is
simply no SDK model for jobs). Aggregation chosen: avg(temperature) over a
1-minute tumbling window. Flink windows by arrival time (event_time is
processing time at Flink, watermark -5s), so one back-to-back burst lands in
a single window and the expected average is exact. Residual risk: a burst
straddling a minute boundary splits across two windows — the burst is a
single produce call (milliseconds), so this is negligible.
Requires the server's idle-timeout SET statement
(table.exec.source.idle-timeout): without it the source watermark freezes
after a finite burst and the window never fires.
"""

import contextlib
from datetime import datetime, timedelta, timezone

import pytest
from conftest import requires_api, unique_name, wait_for

pytestmark = pytest.mark.e2e

PIPE_TEMPS = [20.0, 22.0, 24.0]
EXPECTED_AVG = sum(PIPE_TEMPS) / len(PIPE_TEMPS)

JOB_BODY = {
    "attribute": "temperature",
    "metric": "avg",
    "window_type": "tumbling",
    "window_size": 1,
    "unit": "minute",
}


def _jobs_path(project_id, collection_id, suffix=""):
    return f"/api/v1/projects/{project_id}/collections/{collection_id}/jobs{suffix}"


@requires_api
def test_flink_pipeline_avg(admin_client):
    from nostradamus_ioto_sdk.exceptions import APIError
    from nostradamus_ioto_sdk.models import KeyType

    # 1. Project
    project = admin_client.projects.create(
        name=unique_name("pipe"),
        description="sdk e2e flink pipeline",
        tags=["e2e", "pipeline"],
    )
    try:
        # 2. READ + WRITE keys
        read_key = admin_client.project_keys.create(project.project_id, KeyType.READ)
        write_key = admin_client.project_keys.create(project.project_id, KeyType.WRITE)
        assert read_key.api_key and write_key.api_key
        assert read_key.api_key != write_key.api_key
        listed = admin_client.project_keys.list(project.project_id)
        assert len(listed) >= 2

        # 3. Collection
        collection = admin_client.collections.create(
            project_id=project.project_id,
            name=unique_name("pipecoll"),
            description="sdk e2e flink pipeline collection",
            tags=["e2e", "pipeline"],
            collection_schema={
                "key": "PIPE_001",
                "timestamp": "2026-01-01T00:00:00Z",
                "temperature": 20.0,
                "humidity": 50.0,
            },
        )
        try:
            base = datetime.now(timezone.utc).replace(microsecond=0)

            # 5. Define the aggregation (guided avg job). 503 = no Flink
            # SQL Gateway in this environment → skip, don't fail.
            try:
                job = admin_client.request(
                    "POST",
                    _jobs_path(project.project_id, collection.collection_id),
                    json=JOB_BODY,
                ).json()
            except APIError as exc:
                if getattr(exc, "status_code", None) == 503:
                    pytest.skip("Flink SQL Gateway unavailable in this environment")
                raise
            job_id = job["id"]
            assert job["status"] in ("RUNNING", "PENDING")
            try:
                # 4. Send one back-to-back burst (single window expected).
                # All records share ONE key: the guided job GROUPs BY key, so
                # a single group yields record_count == len(PIPE_TEMPS).
                # The shared key doubles as the readability probe below,
                # so no extra record pollutes the window.
                probe_key = unique_name("pipeburst")
                admin_client.data.send(
                    project_id=project.project_id,
                    collection_id=collection.collection_id,
                    data=[
                        {
                            "key": probe_key,
                            "timestamp": (base - timedelta(seconds=10 * i))
                            .isoformat()
                            .replace("+00:00", "Z"),
                            "temperature": temp,
                            "humidity": 50.0 + i,
                        }
                        for i, temp in enumerate(PIPE_TEMPS)
                    ],
                )

                # 4b. Receive: prove the burst is queryable (Cassandra path)
                # via the shared burst key — no extra send, window stays pure.

                def _query_one():
                    return admin_client.data.get(
                        project_id=project.project_id,
                        collection_id=collection.collection_id,
                        filters=[
                            {
                                "property_name": "key",
                                "operator": "eq",
                                "property_value": probe_key,
                            }
                        ],
                        limit=10,
                    )

                seen = wait_for(
                    _query_one,
                    lambda r: len(r.data) >= len(PIPE_TEMPS),
                    desc="pipeline burst to become readable",
                )
                assert sorted(d["temperature"] for d in seen.data) == sorted(PIPE_TEMPS)

                # 6. Observe the aggregation on the sink topic via results
                def _query_results():
                    return admin_client.request(
                        "GET",
                        _jobs_path(
                            project.project_id,
                            collection.collection_id,
                            f"/{job_id}/results?limit=100",
                        ),
                    ).json()

                results = wait_for(
                    _query_results,
                    lambda r: any(
                        item.get("record_count") == len(PIPE_TEMPS) for item in r.get("items", [])
                    ),
                    desc="avg(temperature) window with full burst",
                )
                row = next(
                    item for item in results["items"] if item.get("record_count") == len(PIPE_TEMPS)
                )
                # Sink column is {metric}_{attribute}, e.g. avg_temperature.
                value_key = f"{JOB_BODY['metric']}_{JOB_BODY['attribute']}"
                assert row[value_key] is not None
                assert abs(row[value_key] - EXPECTED_AVG) < 1e-6
            finally:
                # 7a. Stop + delete the job (DELETE cancels the gateway session)
                with contextlib.suppress(Exception):
                    admin_client.request(
                        "DELETE",
                        _jobs_path(project.project_id, collection.collection_id, f"/{job_id}"),
                    )
        finally:
            # 7b. Collection, then project (keys die with the project)
            with contextlib.suppress(Exception):
                admin_client.collections.delete(project.project_id, collection.collection_id)
    finally:
        with contextlib.suppress(Exception):
            admin_client.projects.delete(project.project_id)
