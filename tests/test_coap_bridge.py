import importlib.util
import json
import os
import sys
import time
from unittest.mock import AsyncMock, MagicMock, patch

_BRIDGE_PATH = os.path.join(os.path.dirname(__file__), "..", "coap-bridge", "coap_bridge.py")
_spec = importlib.util.spec_from_file_location("coap_bridge", _BRIDGE_PATH)
assert _spec and _spec.loader

import types

_aiocoap_mock = types.ModuleType("aiocoap")
_aiocoap_mock.POST = MagicMock(name="POST")
_aiocoap_mock.Message = MagicMock()
_aiocoap_mock.Context = MagicMock()


class _MockResource:
    pass


class _MockPathCapable:
    pass


class _MockSite:
    def __init__(self):
        self._resources = {}

    def add_resource(self, path, resource):
        pass

    def get_child(self, name, request):
        raise KeyError(name)

    def get_resources_as_linkheader(self):
        return ""


_resource_mod = types.ModuleType("aiocoap.resource")
_resource_mod.Resource = _MockResource
_resource_mod.PathCapable = _MockPathCapable
_resource_mod.Site = _MockSite
_resource_mod.WKCResource = MagicMock()

_codes_mod = types.ModuleType("aiocoap.numbers.codes")
_Code = MagicMock()
_Code.METHOD_NOT_ALLOWED = "4.05"
_Code.BAD_REQUEST = "4.00"
_Code.REQUEST_ENTITY_TOO_LARGE = "4.13"
_Code.UNAUTHORIZED = "4.01"
_Code.CHANGED = "2.04"
_codes_mod.Code = _Code

_codes_mock = MagicMock()

_Code = MagicMock()
_Code.METHOD_NOT_ALLOWED = "4.05"
_Code.BAD_REQUEST = "4.00"
_Code.REQUEST_ENTITY_TOO_LARGE = "4.13"
_Code.UNAUTHORIZED = "4.01"
_Code.CHANGED = "2.04"
sys.modules["aiocoap"] = _aiocoap_mock
sys.modules["aiocoap.resource"] = _resource_mod
sys.modules["aiocoap.numbers"] = types.ModuleType("aiocoap.numbers")
sys.modules["aiocoap.numbers.codes"] = _codes_mod
sys.modules.setdefault("cassandra", MagicMock())
sys.modules.setdefault("cassandra.auth", MagicMock())
sys.modules.setdefault("cassandra.cluster", MagicMock())
sys.modules.setdefault("confluent_kafka", MagicMock())

_mod = importlib.util.module_from_spec(_spec)
sys.modules["coap_bridge"] = _mod
_spec.loader.exec_module(_mod)

_build_envelope = _mod._build_envelope
_build_producer = _mod._build_producer
_hash_key = _mod._hash_key
_authenticate = _mod._authenticate


class TestBuildEnvelope:
    def test_json_payload_is_parsed(self):
        raw = b'{"temperature": 22.5}'
        envelope = _build_envelope("org/project/collection", raw, "proj-uuid-123")

        assert envelope["coap_path"] == "org/project/collection"
        assert envelope["payload"] == {"temperature": 22.5}
        assert envelope["client_id"] == "proj-uuid-123"
        assert "ts" in envelope
        assert isinstance(envelope["ts"], int)

    def test_non_json_string_is_wrapped(self):
        raw = b"plain text value"
        envelope = _build_envelope("org/project/collection", raw, "proj-uuid-123")

        assert envelope["payload"] == "plain text value"

    def test_binary_non_utf8_is_hex_encoded(self):
        raw = bytes([0xFF, 0xFE, 0x00, 0x01])
        envelope = _build_envelope("org/project/collection", raw, "proj-uuid-123")

        assert envelope["payload"] == raw.hex()

    def test_timestamp_is_unix_milliseconds(self):
        before = int(time.time() * 1000)
        raw = b'{"x": 1}'
        envelope = _build_envelope("org/project/collection", raw, "proj-uuid-123")
        after = int(time.time() * 1000)

        assert before <= envelope["ts"] <= after

    def test_nested_json_preserved(self):
        raw = b'{"sensor": {"type": "temp", "value": 21.0}}'
        envelope = _build_envelope("org/project/collection", raw, "proj-uuid-123")

        assert envelope["payload"] == {"sensor": {"type": "temp", "value": 21.0}}

    def test_json_list_payload(self):
        raw = b"[1, 2, 3]"
        envelope = _build_envelope("org/project/collection", raw, "proj-uuid-123")

        assert envelope["payload"] == [1, 2, 3]

    def test_envelope_uses_coap_path_not_mqtt_topic(self):
        raw = b'{"x": 1}'
        envelope = _build_envelope("myorg/myproject/sensors", raw, "proj-uuid-123")

        assert "coap_path" in envelope
        assert "mqtt_topic" not in envelope


class TestHashKey:
    def test_returns_sha256_hex(self):
        result = _hash_key("secret123")
        assert len(result) == 64
        assert all(c in "0123456789abcdef" for c in result)

    def test_deterministic(self):
        assert _hash_key("abc") == _hash_key("abc")

    def test_different_keys_differ(self):
        assert _hash_key("key1") != _hash_key("key2")


class TestAuthenticate:
    def setup_method(self):
        _mod._cassandra_session = MagicMock()

    def teardown_method(self):
        _mod._cassandra_session = None

    def _make_key_row(self, project_id, key_type="write"):
        row = MagicMock()
        row.project_id = project_id
        row.key_type = key_type
        return row

    def _make_org_row(self, name):
        row = MagicMock()
        row.organization_name = name
        return row

    def _make_project_row(self, name):
        row = MagicMock()
        row.project_name = name
        return row

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_valid_write_key_returns_project_id(self):
        import uuid

        project_id = uuid.uuid4()
        _mod._cassandra_session.execute.side_effect = [
            MagicMock(one=MagicMock(return_value=self._make_key_row(project_id, "write"))),
            MagicMock(one=MagicMock(return_value=self._make_org_row("myorg"))),
            MagicMock(one=MagicMock(return_value=self._make_project_row("myproject"))),
        ]

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result == str(project_id)

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_valid_master_key_returns_project_id(self):
        import uuid

        project_id = uuid.uuid4()
        _mod._cassandra_session.execute.side_effect = [
            MagicMock(one=MagicMock(return_value=self._make_key_row(project_id, "master"))),
            MagicMock(one=MagicMock(return_value=self._make_org_row("myorg"))),
            MagicMock(one=MagicMock(return_value=self._make_project_row("myproject"))),
        ]

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result == str(project_id)

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_read_key_is_rejected(self):
        import uuid

        _mod._cassandra_session.execute.return_value = MagicMock(
            one=MagicMock(return_value=self._make_key_row(uuid.uuid4(), "read"))
        )

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result is None

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_key_not_found_returns_none(self):
        _mod._cassandra_session.execute.return_value = MagicMock(one=MagicMock(return_value=None))

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result is None

    @patch("coap_bridge.ORGANIZATION_ID", "not-a-uuid")
    def test_invalid_organization_id_returns_none(self):
        import uuid

        _mod._cassandra_session.execute.return_value = MagicMock(
            one=MagicMock(return_value=self._make_key_row(uuid.uuid4(), "write"))
        )

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result is None

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_org_name_mismatch_returns_none(self):
        import uuid

        _mod._cassandra_session.execute.side_effect = [
            MagicMock(one=MagicMock(return_value=self._make_key_row(uuid.uuid4(), "write"))),
            MagicMock(one=MagicMock(return_value=self._make_org_row("otherorg"))),
        ]

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result is None

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_project_name_mismatch_returns_none(self):
        import uuid

        _mod._cassandra_session.execute.side_effect = [
            MagicMock(one=MagicMock(return_value=self._make_key_row(uuid.uuid4(), "write"))),
            MagicMock(one=MagicMock(return_value=self._make_org_row("myorg"))),
            MagicMock(one=MagicMock(return_value=self._make_project_row("otherproject"))),
        ]

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result is None

    @patch("coap_bridge.ORGANIZATION_ID", "123e4567-e89b-12d3-a456-426614174000")
    def test_cassandra_error_returns_none(self):
        _mod._cassandra_session.execute.side_effect = Exception("connection refused")

        result = _authenticate("rawkey", "myorg", "myproject")
        assert result is None


class TestBuildProducer:
    @patch("coap_bridge.KAFKA_USERNAME", "")
    @patch("coap_bridge.KAFKA_PASSWORD", "")
    @patch("coap_bridge.Producer")
    def test_no_sasl_without_credentials(self, mock_producer_cls):
        _build_producer()

        config = mock_producer_cls.call_args[0][0]
        assert "security.protocol" not in config
        assert "sasl.mechanism" not in config
        assert "bootstrap.servers" in config

    @patch("coap_bridge.KAFKA_USERNAME", "testuser")
    @patch("coap_bridge.KAFKA_PASSWORD", "secret")
    @patch("coap_bridge.KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
    @patch("coap_bridge.KAFKA_SASL_MECHANISM", "PLAIN")
    @patch("coap_bridge.Producer")
    def test_sasl_included_when_credentials_set(self, mock_producer_cls):
        _build_producer()

        config = mock_producer_cls.call_args[0][0]
        assert config["security.protocol"] == "SASL_PLAINTEXT"
        assert config["sasl.mechanism"] == "PLAIN"
        assert config["sasl.username"] == "testuser"
        assert config["sasl.password"] == "secret"
