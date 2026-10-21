"""E2E: users lifecycle + negative/error cases."""

import uuid

import pytest
from conftest import requires_api, unique_name

pytestmark = pytest.mark.e2e


@requires_api
def test_users_lifecycle(admin_client, e2e_env, e2e_org):
    from nostradamus_ioto_sdk import NostradamusClient
    from nostradamus_ioto_sdk.exceptions import NostradamusError

    org = e2e_org
    username = unique_name("user")
    password = "E2e_Probe_123!"

    admin_client.users.create(
        organization_id=org.organization_id,
        username=username,
        password=password,
    )
    try:
        assert username in admin_client.users.list(org.organization_id)

        new_password = "E2e_Probe_456!"
        admin_client.users.update_password(org.organization_id, username, new_password)

        user_client = NostradamusClient(
            base_url=e2e_env["base_url"], username=username, password=new_password
        )
        try:
            assert user_client.organizations.get().organization_id == org.organization_id
        finally:
            user_client.close()
    finally:
        admin_client.users.delete(org.organization_id, username)

    assert username not in admin_client.users.list(org.organization_id)

    deleted_client = NostradamusClient(
        base_url=e2e_env["base_url"], username=username, password=new_password
    )
    try:
        with pytest.raises(NostradamusError):
            deleted_client.organizations.get()
    finally:
        deleted_client.close()


@requires_api
def test_negative_bad_password(e2e_env):
    from nostradamus_ioto_sdk import NostradamusClient
    from nostradamus_ioto_sdk.exceptions import AuthenticationError

    bad_client = NostradamusClient(
        base_url=e2e_env["base_url"],
        username=e2e_env["username"],
        password="definitely-wrong-password",
    )
    try:
        with pytest.raises(AuthenticationError):
            bad_client.organizations.get()
    finally:
        bad_client.close()


@requires_api
def test_negative_invalid_api_key(e2e_env):
    from nostradamus_ioto_sdk import NostradamusClient
    from nostradamus_ioto_sdk.exceptions import NostradamusError

    bad_client = NostradamusClient(base_url=e2e_env["base_url"], api_key="invalid-key")
    try:
        with pytest.raises(NostradamusError):
            bad_client.projects.list()
    finally:
        bad_client.close()


@requires_api
def test_negative_unknown_project_uuid(admin_client):
    from nostradamus_ioto_sdk.exceptions import ResourceNotFoundError

    with pytest.raises(ResourceNotFoundError):
        admin_client.projects.get(uuid.uuid4())


@requires_api
def test_negative_malformed_data_payload(admin_client, e2e_project, e2e_collection):
    from nostradamus_ioto_sdk.exceptions import APIError

    with pytest.raises(APIError):
        admin_client.data.send(
            project_id=e2e_project.project_id,
            collection_id=e2e_collection.collection_id,
            # 'bogus_field_xyz' is not in the collection schema -> API rejects
            data={"key": "e2e_bad_1", "bogus_field_xyz": 1},
        )
