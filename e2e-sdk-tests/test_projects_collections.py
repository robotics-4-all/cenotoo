"""E2E: projects + collections full CRUD lifecycles."""

import uuid

import pytest
from conftest import requires_api, unique_name

pytestmark = pytest.mark.e2e


@requires_api
def test_projects_crud_lifecycle(admin_client):
    from nostradamus_ioto_sdk.exceptions import ResourceNotFoundError

    baseline_ids = {str(p.project_id) for p in admin_client.projects.list()}

    project = admin_client.projects.create(
        name=unique_name("proj"),
        description="sdk e2e project lifecycle",
        tags=["e2e"],
    )
    try:
        assert str(project.project_id) not in baseline_ids

        fetched = admin_client.projects.get(project.project_id)
        assert fetched.project_name == project.project_name

        updated = admin_client.projects.update(
            project.project_id, description="sdk e2e updated", tags=["e2e", "updated"]
        )
        assert updated.description == "sdk e2e updated"

        ids = {str(p.project_id) for p in admin_client.projects.list()}
        assert str(project.project_id) in ids
    finally:
        admin_client.projects.delete(project.project_id)

    with pytest.raises(ResourceNotFoundError):
        admin_client.projects.get(project.project_id)


@requires_api
def test_projects_get_unknown_uuid_raises(admin_client):
    from nostradamus_ioto_sdk.exceptions import ResourceNotFoundError

    with pytest.raises(ResourceNotFoundError):
        admin_client.projects.get(uuid.uuid4())


@requires_api
def test_collections_crud_lifecycle(admin_client, e2e_project):
    from nostradamus_ioto_sdk.exceptions import ResourceNotFoundError

    collection = admin_client.collections.create(
        project_id=e2e_project.project_id,
        name=unique_name("coll"),
        description="sdk e2e collection lifecycle",
        tags=["e2e"],
        collection_schema={"key": "K1", "timestamp": "2026-01-01T00:00:00Z", "v": 1.0},
    )
    try:
        fetched = admin_client.collections.get(e2e_project.project_id, collection.collection_id)
        assert fetched.collection_name == collection.collection_name

        updated = admin_client.collections.update(
            e2e_project.project_id,
            collection.collection_id,
            description="sdk e2e collection updated",
        )
        assert updated.description == "sdk e2e collection updated"

        items = admin_client.collections.list(e2e_project.project_id)
        names = {str(c.collection_id) for c in items}
        assert str(collection.collection_id) in names
    finally:
        admin_client.collections.delete(e2e_project.project_id, collection.collection_id)

    with pytest.raises(ResourceNotFoundError):
        admin_client.collections.get(e2e_project.project_id, collection.collection_id)


@requires_api
def test_collections_duplicate_name_conflicts(admin_client, e2e_project):
    from nostradamus_ioto_sdk.exceptions import APIError

    name = unique_name("dup")
    kwargs = {
        "project_id": e2e_project.project_id,
        "name": name,
        "description": "dup probe",
        "collection_schema": {"key": "K1"},
    }
    first = admin_client.collections.create(**kwargs)
    try:
        with pytest.raises(APIError):
            admin_client.collections.create(**kwargs)
    finally:
        admin_client.collections.delete(e2e_project.project_id, first.collection_id)
