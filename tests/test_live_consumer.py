import importlib.util
import os
import sys
from unittest.mock import MagicMock, patch

from confluent_kafka import KafkaError

_CONSUMER_PATH = os.path.join(os.path.dirname(__file__), "..", "kafka-live-consumer", "consumer.py")
_spec = importlib.util.spec_from_file_location("live_consumer", _CONSUMER_PATH)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
sys.modules["live_consumer"] = _mod
_spec.loader.exec_module(_mod)

get_kafka_consumer = _mod.get_kafka_consumer
consume_and_broadcast = _mod.consume_and_broadcast


class TestGetKafkaConsumer:
    @patch("live_consumer.Consumer")
    def test_creates_consumer_with_config(self, mock_consumer_cls):
        get_kafka_consumer()

        mock_consumer_cls.assert_called_once()
        config = mock_consumer_cls.call_args[0][0]
        assert "bootstrap.servers" in config
        assert "group.id" in config
        assert config["auto.offset.reset"] == "latest"


class TestConsumeAndBroadcast:
    def test_processes_message(self):
        mock_consumer = MagicMock()
        msg = MagicMock()
        msg.error.return_value = None
        msg.value.return_value = b'{"data": "test"}'

        call_count = [0]

        def poll_with_shutdown(timeout):
            call_count[0] += 1
            if call_count[0] == 1:
                return msg
            _mod._shutdown = True
            return None

        mock_consumer.poll.side_effect = poll_with_shutdown
        _mod._shutdown = False

        consume_and_broadcast(mock_consumer, "test_topic")

        mock_consumer.subscribe.assert_called_once_with(["test_topic"])
        mock_consumer.close.assert_called_once()
        _mod._shutdown = False

    def test_handles_partition_eof(self):
        mock_consumer = MagicMock()

        eof_msg = MagicMock()
        eof_error = MagicMock()
        eof_error.code.return_value = KafkaError._PARTITION_EOF
        eof_msg.error.return_value = eof_error

        call_count = [0]

        def poll_with_shutdown(timeout):
            call_count[0] += 1
            if call_count[0] == 1:
                return eof_msg
            _mod._shutdown = True
            return None

        mock_consumer.poll.side_effect = poll_with_shutdown
        _mod._shutdown = False

        consume_and_broadcast(mock_consumer, "test_topic")

        mock_consumer.close.assert_called_once()
        _mod._shutdown = False

    def test_closes_consumer_on_shutdown(self):
        mock_consumer = MagicMock()

        def immediate_shutdown(timeout):
            _mod._shutdown = True
            return None

        mock_consumer.poll.side_effect = immediate_shutdown
        _mod._shutdown = False

        consume_and_broadcast(mock_consumer, "test_topic")

        mock_consumer.close.assert_called_once()
        _mod._shutdown = False
