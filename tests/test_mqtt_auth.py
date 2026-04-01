import importlib.util
import os
import sys
from unittest.mock import MagicMock

_AUTH_PATH = os.path.join(os.path.dirname(__file__), "..", "mqtt-auth", "mqtt_auth.py")
_spec = importlib.util.spec_from_file_location("mqtt_auth", _AUTH_PATH)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
sys.modules["mqtt_auth"] = _mod

_hash_key = _mod._hash_key
_lookup_key = _mod._lookup_key
_lookup_org = _mod._lookup_org
_lookup_project = _mod._lookup_project


def _make_row(**kwargs):
    row = MagicMock()
    for k, v in kwargs.items():
        setattr(row, k, v)
    return row


class TestHashKey:
    def test_returns_64_char_hex(self):
        result = _hash_key("somekey")
        assert len(result) == 64
        assert all(c in "0123456789abcdef" for c in result)

    def test_same_input_same_hash(self):
        assert _hash_key("abc") == _hash_key("abc")

    def test_different_inputs_different_hashes(self):
        assert _hash_key("abc") != _hash_key("xyz")


class TestLookupKey:
    def test_returns_row_on_hit(self):
        _mod._session = MagicMock()
        _mod._session.execute.return_value.one.return_value = _make_row(key_type="write")
        import uuid

        row = _lookup_key("hashed", uuid.uuid4())
        assert row.key_type == "write"

    def test_returns_none_on_cassandra_error(self):
        _mod._session = MagicMock()
        _mod._session.execute.side_effect = Exception("connection refused")
        import uuid

        assert _lookup_key("hashed", uuid.uuid4()) is None

    def test_returns_none_when_no_row(self):
        _mod._session = MagicMock()
        _mod._session.execute.return_value.one.return_value = None
        import uuid

        assert _lookup_key("hashed", uuid.uuid4()) is None


class TestLookupOrg:
    def test_returns_org_row(self):
        _mod._session = MagicMock()
        _mod._session.execute.return_value.one.return_value = _make_row(organization_name="acme")
        import uuid

        row = _lookup_org(uuid.uuid4())
        assert row.organization_name == "acme"

    def test_returns_none_on_error(self):
        _mod._session = MagicMock()
        _mod._session.execute.side_effect = Exception("timeout")
        import uuid

        assert _lookup_org(uuid.uuid4()) is None


class TestLookupProject:
    def test_returns_project_row(self):
        _mod._session = MagicMock()
        _mod._session.execute.return_value.one.return_value = _make_row(project_name="iot")
        import uuid

        row = _lookup_project(uuid.uuid4(), uuid.uuid4())
        assert row.project_name == "iot"

    def test_returns_none_on_error(self):
        _mod._session = MagicMock()
        _mod._session.execute.side_effect = Exception("timeout")
        import uuid

        assert _lookup_project(uuid.uuid4(), uuid.uuid4()) is None


class TestAuthUser:
    def setup_method(self):
        _mod.MQTT_BRIDGE_USERNAME = "cenotoo-bridge"
        _mod.MQTT_BRIDGE_PASSWORD = "secret"
        _mod._session = MagicMock()

    def _post(self, data):
        with _mod.app.test_client() as c:
            return c.post("/auth/user", json=data)

    def test_bridge_valid_credentials_allowed(self):
        r = self._post({"username": "cenotoo-bridge", "password": "secret", "clientid": "br1"})
        assert r.status_code == 200

    def test_bridge_wrong_password_denied(self):
        r = self._post({"username": "cenotoo-bridge", "password": "wrong", "clientid": "br1"})
        assert r.status_code == 403

    def test_bridge_empty_password_config_denied(self):
        _mod.MQTT_BRIDGE_PASSWORD = ""
        r = self._post({"username": "cenotoo-bridge", "password": "", "clientid": "br1"})
        assert r.status_code == 403

    def test_device_valid_write_key_allowed(self):
        import uuid

        project_id = uuid.uuid4()
        _mod._session.execute.return_value.one.return_value = _make_row(key_type="write")
        r = self._post({"username": str(project_id), "password": "a" * 64, "clientid": "dev1"})
        assert r.status_code == 200

    def test_device_valid_master_key_allowed(self):
        import uuid

        project_id = uuid.uuid4()
        _mod._session.execute.return_value.one.return_value = _make_row(key_type="master")
        r = self._post({"username": str(project_id), "password": "b" * 64, "clientid": "dev1"})
        assert r.status_code == 200

    def test_device_read_key_denied(self):
        import uuid

        project_id = uuid.uuid4()
        _mod._session.execute.return_value.one.return_value = _make_row(key_type="read")
        r = self._post({"username": str(project_id), "password": "c" * 64, "clientid": "dev1"})
        assert r.status_code == 403

    def test_device_key_not_found_denied(self):
        import uuid

        _mod._session.execute.return_value.one.return_value = None
        r = self._post({"username": str(uuid.uuid4()), "password": "d" * 64, "clientid": "dev1"})
        assert r.status_code == 403

    def test_invalid_uuid_username_denied(self):
        r = self._post({"username": "not-a-uuid", "password": "key", "clientid": "dev1"})
        assert r.status_code == 403

    def test_empty_body_uses_defaults_and_denies(self):
        r = self._post({})
        assert r.status_code == 403


class TestAuthAcl:
    def setup_method(self):
        _mod.MQTT_BRIDGE_USERNAME = "cenotoo-bridge"
        _mod.MQTT_BRIDGE_PASSWORD = "secret"
        _mod.ORGANIZATION_ID = "00000000-0000-0000-0000-000000000001"
        _mod._session = MagicMock()

    def _post(self, data):
        with _mod.app.test_client() as c:
            return c.post("/auth/acl", json=data)

    def _mock_org_and_project(self, org_name, project_name):
        results = [
            _make_row(organization_name=org_name),
            _make_row(project_name=project_name),
        ]
        _mod._session.execute.return_value.one.side_effect = results

    def test_bridge_allowed_any_topic(self):
        r = self._post({"username": "cenotoo-bridge", "topic": "x/y/z", "acc": 1})
        assert r.status_code == 200

    def test_device_publish_valid_topic_allowed(self):
        import uuid

        project_id = uuid.uuid4()
        self._mock_org_and_project("acme", "iot")
        r = self._post({"username": str(project_id), "topic": "acme/iot/sensors", "acc": 2})
        assert r.status_code == 200

    def test_device_subscribe_denied(self):
        import uuid

        r = self._post({"username": str(uuid.uuid4()), "topic": "acme/iot/sensors", "acc": 1})
        assert r.status_code == 403

    def test_device_two_segment_topic_denied(self):
        import uuid

        r = self._post({"username": str(uuid.uuid4()), "topic": "acme/iot", "acc": 2})
        assert r.status_code == 403

    def test_device_four_segment_topic_denied(self):
        import uuid

        r = self._post({"username": str(uuid.uuid4()), "topic": "acme/iot/s/x", "acc": 2})
        assert r.status_code == 403

    def test_device_empty_segment_denied(self):
        import uuid

        r = self._post({"username": str(uuid.uuid4()), "topic": "acme//sensors", "acc": 2})
        assert r.status_code == 403

    def test_wrong_org_denied(self):
        import uuid

        project_id = uuid.uuid4()
        self._mock_org_and_project("acme", "iot")
        r = self._post({"username": str(project_id), "topic": "other/iot/sensors", "acc": 2})
        assert r.status_code == 403

    def test_wrong_project_denied(self):
        import uuid

        project_id = uuid.uuid4()
        results = [
            _make_row(organization_name="acme"),
            _make_row(project_name="other"),
        ]
        _mod._session.execute.return_value.one.side_effect = results
        r = self._post({"username": str(project_id), "topic": "acme/iot/sensors", "acc": 2})
        assert r.status_code == 403

    def test_invalid_org_id_config_denied(self):
        _mod.ORGANIZATION_ID = "not-a-uuid"
        import uuid

        r = self._post({"username": str(uuid.uuid4()), "topic": "acme/iot/sensors", "acc": 2})
        assert r.status_code == 403

    def test_invalid_username_uuid_denied(self):
        _mod._session.execute.return_value.one.return_value = _make_row(organization_name="acme")
        r = self._post({"username": "not-a-uuid", "topic": "acme/iot/sensors", "acc": 2})
        assert r.status_code == 403


class TestHealthEndpoint:
    def test_returns_200(self):
        with _mod.app.test_client() as c:
            r = c.get("/health")
            assert r.status_code == 200
