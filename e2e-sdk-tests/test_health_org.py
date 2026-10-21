"""E2E: health/ready + organizations get/update."""

import pytest
from conftest import requires_api

pytestmark = pytest.mark.e2e


@requires_api
def test_health_and_ready(admin_client):
    health = admin_client.health.health()
    assert health.status.lower() in ("ok", "up", "healthy", "200")
    ready = admin_client.health.ready()
    assert ready.status.lower() in ("ok", "up", "ready", "healthy")


@requires_api
def test_organization_get_and_update_roundtrip(admin_client, e2e_org):
    org = e2e_org
    assert org.organization_id is not None
    assert org.organization_name
    original_desc = org.description or ""

    suffix = "e2e-probe"
    updated = admin_client.organizations.update(description=f"{original_desc} {suffix}".strip())
    assert suffix in (updated.description or "")
    restored = admin_client.organizations.update(description=original_desc or None)
    assert suffix not in (restored.description or "")
