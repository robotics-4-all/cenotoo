"""Shared fixtures for SDK-level e2e tests (require live Cenotoo API)."""

import contextlib
import os
import random
import re
import time
from collections.abc import Callable
from typing import Any

import pytest

pytestmark = pytest.mark.e2e

BASE_URL = os.getenv("CENOTOO_BASE_URL", "")
USERNAME = os.getenv("CENOTOO_USERNAME", "")
PASSWORD = os.getenv("CENOTOO_PASSWORD", "")
E2E_PREFIX = os.getenv("E2E_PREFIX", "e2e")
E2E_TIMEOUT_S = float(os.getenv("E2E_TIMEOUT_S", "300"))
E2E_INTERVAL_S = float(os.getenv("E2E_INTERVAL_S", "2"))

CREDS_CONFIGURED = bool(BASE_URL and USERNAME and PASSWORD)


def requires_api(func):
    return pytest.mark.skipif(
        not CREDS_CONFIGURED,
        reason="Set CENOTOO_BASE_URL, CENOTOO_USERNAME, CENOTOO_PASSWORD to run e2e",
    )(func)


def unique_name(prefix: str = "case") -> str:
    # API rule: names may contain only latin letters, numbers and underscores.
    # Underscores everywhere (incl. sanitized E2E_PREFIX) keep every create green.
    safe_prefix = re.sub(r"[^A-Za-z0-9_]", "_", E2E_PREFIX)
    stamp = int(time.time())
    rand = random.randint(1000, 9999)
    return f"{safe_prefix}_{prefix}_{stamp}_{rand}"


def wait_for(
    fn: Callable[[], Any],
    predicate: Callable[[Any], bool],
    timeout: float = E2E_TIMEOUT_S,
    interval: float = E2E_INTERVAL_S,
    desc: str = "condition",
) -> Any:
    """Poll fn() until predicate(result) is True; raise with last result on timeout."""
    deadline = time.monotonic() + timeout
    last: Any = None
    start = time.monotonic()
    next_heartbeat = start + 30
    while time.monotonic() < deadline:
        last = fn()
        try:
            if predicate(last):
                return last
        except Exception:
            pass
        now = time.monotonic()
        if now >= next_heartbeat:
            print(f"[e2e] still waiting for {desc} after {now - start:.0f}s: {last!r}")
            next_heartbeat = now + 30
        time.sleep(interval)
    raise TimeoutError(f"Timed out waiting for {desc}. Last result: {last!r}")


@pytest.fixture(scope="session")
def e2e_env():
    if not CREDS_CONFIGURED:
        pytest.skip("e2e requires CENOTOO_BASE_URL + CENOTOO_USERNAME + CENOTOO_PASSWORD")
    return {"base_url": BASE_URL, "username": USERNAME, "password": PASSWORD}


@pytest.fixture(scope="session")
def admin_client(e2e_env):
    from nostradamus_ioto_sdk import NostradamusClient

    client = NostradamusClient(
        base_url=e2e_env["base_url"],
        username=e2e_env["username"],
        password=e2e_env["password"],
    )
    yield client
    client.close()


@pytest.fixture(scope="session")
def e2e_project(admin_client):
    project = admin_client.projects.create(
        name=unique_name("project"),
        description="sdk e2e test project",
        tags=["e2e", "sdk"],
    )
    yield project
    with contextlib.suppress(Exception):
        admin_client.projects.delete(project.project_id)


@pytest.fixture(scope="session")
def e2e_collection(admin_client, e2e_project):
    collection = admin_client.collections.create(
        project_id=e2e_project.project_id,
        name=unique_name("collection"),
        description="sdk e2e test collection",
        tags=["e2e", "sdk"],
        collection_schema={
            "key": "E2E_001",
            "timestamp": "2026-01-01T00:00:00Z",
            "temperature": 20.0,
            "humidity": 50.0,
        },
    )
    yield collection
    with contextlib.suppress(Exception):
        admin_client.collections.delete(e2e_project.project_id, collection.collection_id)


@pytest.fixture(scope="session")
def e2e_org(admin_client):
    """Default organization, or skip when the server does not have it.

    The SDK addresses the organization as 'nostradamus'; servers seeded
    without that organization answer 404 — org/user coverage then skips
    instead of failing.
    """
    from nostradamus_ioto_sdk.exceptions import ResourceNotFoundError

    try:
        return admin_client.organizations.get()
    except ResourceNotFoundError:
        pytest.skip("default organization 'nostradamus' not present on this server")
