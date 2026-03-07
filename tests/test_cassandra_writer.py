import importlib.util
import os
import sys
from unittest.mock import MagicMock, patch

import pytest

_CONSUMER_PATH = os.path.join(os.path.dirname(__file__), "..", "kafka-to-cassandra", "consumer.py")
_spec = importlib.util.spec_from_file_location("cassandra_writer", _CONSUMER_PATH)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
sys.modules["cassandra_writer"] = _mod
_spec.loader.exec_module(_mod)

_validate_identifier = _mod._validate_identifier
_connect_cassandra = _mod._connect_cassandra


class TestValidateIdentifier:
    def test_valid_simple_name(self):
        assert _validate_identifier("temperature") == "temperature"

    def test_valid_underscore_prefix(self):
        assert _validate_identifier("_private") == "_private"

    def test_valid_mixed_case(self):
        assert _validate_identifier("myColumn_123") == "myColumn_123"

    def test_rejects_sql_injection(self):
        with pytest.raises(ValueError, match="Invalid CQL identifier"):
            _validate_identifier("col; DROP TABLE users")

    def test_rejects_dash(self):
        with pytest.raises(ValueError, match="Invalid CQL identifier"):
            _validate_identifier("my-column")

    def test_rejects_dot(self):
        with pytest.raises(ValueError, match="Invalid CQL identifier"):
            _validate_identifier("schema.table")

    def test_rejects_space(self):
        with pytest.raises(ValueError, match="Invalid CQL identifier"):
            _validate_identifier("my column")

    def test_rejects_empty(self):
        with pytest.raises(ValueError, match="Invalid CQL identifier"):
            _validate_identifier("")

    def test_rejects_starts_with_number(self):
        with pytest.raises(ValueError, match="Invalid CQL identifier"):
            _validate_identifier("1column")


class TestConnectCassandra:
    @patch("cassandra_writer.Cluster")
    def test_connects_on_first_attempt(self, mock_cluster_cls):
        mock_session = MagicMock()
        mock_cluster_cls.return_value.connect.return_value = mock_session

        cluster, session = _connect_cassandra(["localhost"], 9042, max_retries=3)

        mock_cluster_cls.assert_called_once_with(["localhost"], port=9042)
        assert session is mock_session

    @patch("cassandra_writer.time.sleep")
    @patch("cassandra_writer.Cluster")
    def test_retries_on_failure(self, mock_cluster_cls, mock_sleep):
        mock_session = MagicMock()
        mock_cluster_cls.return_value.connect.side_effect = [
            ConnectionError("refused"),
            mock_session,
        ]

        cluster, session = _connect_cassandra(["localhost"], 9042, max_retries=3)

        assert mock_cluster_cls.call_count == 2
        assert session is mock_session
        mock_sleep.assert_called_once()

    @patch("cassandra_writer.time.sleep")
    @patch("cassandra_writer.Cluster")
    def test_raises_after_max_retries(self, mock_cluster_cls, mock_sleep):
        mock_cluster_cls.return_value.connect.side_effect = ConnectionError("refused")

        with pytest.raises(ConnectionError):
            _connect_cassandra(["localhost"], 9042, max_retries=2)

        assert mock_cluster_cls.call_count == 2


class TestConsumeAndStore:
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_processes_message_and_commits(self, mock_consumer_cls, mock_connect):
        mock_session = MagicMock()
        mock_cluster = MagicMock()
        mock_connect.return_value = (mock_cluster, mock_session)

        prepared_stmt = MagicMock()
        mock_session.prepare.return_value = prepared_stmt

        msg = MagicMock()
        msg.error.return_value = None
        msg.value.return_value = b'{"temperature": 22.5}'
        msg.key.return_value = b"sensor_001"

        consumer_instance = mock_consumer_cls.return_value

        _mod._shutdown = False
        poll_responses = [msg, None]
        poll_count = [0]

        def poll_with_shutdown(timeout):
            idx = poll_count[0]
            result = poll_responses[idx] if idx < len(poll_responses) else None
            poll_count[0] += 1
            if poll_count[0] >= 2:
                _mod._shutdown = True
            return result

        consumer_instance.poll.side_effect = poll_with_shutdown

        _mod.consume_and_store("test_topic", "test_org", "test_table")

        mock_session.prepare.assert_called_once()
        mock_session.execute.assert_called_once()
        consumer_instance.commit.assert_called_once()

        _mod._shutdown = False
