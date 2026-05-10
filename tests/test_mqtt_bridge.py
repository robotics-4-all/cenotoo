import importlib.util
import json
import os
import sys
import time
from unittest.mock import MagicMock, patch

_BRIDGE_PATH = os.path.join(os.path.dirname(__file__), "..", "mqtt-bridge", "mqtt_bridge.py")
_spec = importlib.util.spec_from_file_location("mqtt_bridge", _BRIDGE_PATH)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
sys.modules["mqtt_bridge"] = _mod
_spec.loader.exec_module(_mod)

_build_kafka_topic = _mod._build_kafka_topic
_build_envelope = _mod._build_envelope
_build_producer = _mod._build_producer
on_message = _mod.on_message
_signal_handler = _mod._signal_handler


class TestBuildKafkaTopic:
    def test_valid_three_segment_topic(self):
        assert _build_kafka_topic("acme/iot/sensors") == "acme.iot.sensors"

    def test_replaces_slashes_with_dots(self):
        assert _build_kafka_topic("org/project/collection") == "org.project.collection"

    def test_rejects_two_segment_topic(self):
        assert _build_kafka_topic("acme/iot") is None

    def test_rejects_four_segment_topic(self):
        assert _build_kafka_topic("acme/iot/sensors/device_001") is None

    def test_rejects_single_segment(self):
        assert _build_kafka_topic("acme") is None

    def test_rejects_empty_segment(self):
        assert _build_kafka_topic("acme//collection") is None

    def test_rejects_trailing_slash(self):
        assert _build_kafka_topic("acme/iot/") is None

    def test_rejects_leading_slash(self):
        assert _build_kafka_topic("/iot/sensors") is None


class TestBuildEnvelope:
    def test_json_payload_is_parsed(self):
        raw = b'{"temperature": 22.5}'
        envelope = _build_envelope("org/project/collection", raw, "test-bridge")

        assert envelope["mqtt_topic"] == "org/project/collection"
        assert envelope["payload"] == {"temperature": 22.5}
        assert envelope["client_id"] == "test-bridge"
        assert "ts" in envelope
        assert isinstance(envelope["ts"], int)

    def test_non_json_string_is_wrapped(self):
        raw = b"plain text value"
        envelope = _build_envelope("org/project/collection", raw, "test-bridge")

        assert envelope["payload"] == "plain text value"

    def test_binary_non_utf8_is_hex_encoded(self):
        raw = bytes([0xFF, 0xFE, 0x00, 0x01])
        envelope = _build_envelope("org/project/collection", raw, "test-bridge")

        assert envelope["payload"] == raw.hex()

    def test_timestamp_is_unix_milliseconds(self):
        before = int(time.time() * 1000)
        raw = b'{"x": 1}'
        envelope = _build_envelope("org/project/collection", raw, "test-bridge")
        after = int(time.time() * 1000)

        assert before <= envelope["ts"] <= after

    def test_nested_json_preserved(self):
        raw = b'{"sensor": {"type": "temp", "value": 21.0}}'
        envelope = _build_envelope("org/project/collection", raw, "test-bridge")

        assert envelope["payload"] == {"sensor": {"type": "temp", "value": 21.0}}

    def test_json_list_payload(self):
        raw = b"[1, 2, 3]"
        envelope = _build_envelope("org/project/collection", raw, "test-bridge")

        assert envelope["payload"] == [1, 2, 3]


class TestOnMessage:
    def setup_method(self):
        _mod._message_queue.queue.clear()
        _mod._shutdown = False

    def teardown_method(self):
        _mod._shutdown = False

    def test_valid_topic_puts_envelope_on_queue(self):
        msg = MagicMock()
        msg.topic = "acme/iot/sensors"
        msg.payload = b'{"temp": 22.5}'

        on_message(None, None, msg)

        assert _mod._message_queue.qsize() == 1
        kafka_topic, raw_value = _mod._message_queue.get_nowait()
        assert kafka_topic == "acme.iot.sensors"
        envelope = json.loads(raw_value.decode("utf-8"))
        assert envelope["mqtt_topic"] == "acme/iot/sensors"
        assert envelope["payload"] == {"temp": 22.5}
        assert "ts" in envelope
        assert "client_id" in envelope

    def test_two_segment_topic_is_skipped(self):
        msg = MagicMock()
        msg.topic = "acme/iot"
        msg.payload = b'{"temp": 22.5}'

        on_message(None, None, msg)

        assert _mod._message_queue.qsize() == 0

    def test_four_segment_topic_is_skipped(self):
        msg = MagicMock()
        msg.topic = "acme/iot/sensors/device_001"
        msg.payload = b'{"temp": 22.5}'

        on_message(None, None, msg)

        assert _mod._message_queue.qsize() == 0

    def test_non_json_payload_still_enqueued(self):
        msg = MagicMock()
        msg.topic = "acme/iot/sensors"
        msg.payload = b"raw_binary_data"

        on_message(None, None, msg)

        assert _mod._message_queue.qsize() == 1
        _, raw_value = _mod._message_queue.get_nowait()
        envelope = json.loads(raw_value.decode("utf-8"))
        assert envelope["payload"] == "raw_binary_data"


class TestBuildProducer:
    @patch("mqtt_bridge.KAFKA_USERNAME", "")
    @patch("mqtt_bridge.KAFKA_PASSWORD", "")
    @patch("mqtt_bridge.Producer")
    def test_no_sasl_without_credentials(self, mock_producer_cls):
        _build_producer()

        config = mock_producer_cls.call_args[0][0]
        assert "security.protocol" not in config
        assert "sasl.mechanism" not in config
        assert "bootstrap.servers" in config

    @patch("mqtt_bridge.KAFKA_USERNAME", "testuser")
    @patch("mqtt_bridge.KAFKA_PASSWORD", "secret")
    @patch("mqtt_bridge.KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
    @patch("mqtt_bridge.KAFKA_SASL_MECHANISM", "PLAIN")
    @patch("mqtt_bridge.Producer")
    def test_sasl_included_when_credentials_set(self, mock_producer_cls):
        _build_producer()

        config = mock_producer_cls.call_args[0][0]
        assert config["security.protocol"] == "SASL_PLAINTEXT"
        assert config["sasl.mechanism"] == "PLAIN"
        assert config["sasl.username"] == "testuser"
        assert config["sasl.password"] == "secret"


class TestSignalHandler:
    def setup_method(self):
        _mod._shutdown = False

    def teardown_method(self):
        _mod._shutdown = False

    def test_sigterm_sets_shutdown_flag(self):
        assert not _mod._shutdown
        _signal_handler(15, None)
        assert _mod._shutdown

    def test_sigint_sets_shutdown_flag(self):
        assert not _mod._shutdown
        _signal_handler(2, None)
        assert _mod._shutdown
