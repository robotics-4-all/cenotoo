import importlib.util
import json
import logging
import os
import re
import sys
import uuid
from datetime import date
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

        mock_cluster_cls.assert_called_once_with(["localhost"], port=9042, auth_provider=None)
        assert session is mock_session

    @patch("cassandra_writer.PlainTextAuthProvider")
    @patch("cassandra_writer.Cluster")
    def test_connects_with_auth(self, mock_cluster_cls, mock_auth_cls):
        mock_session = MagicMock()
        mock_cluster_cls.return_value.connect.return_value = mock_session
        mock_auth = MagicMock()
        mock_auth_cls.return_value = mock_auth

        cluster, session = _connect_cassandra(
            ["localhost"], 9042, username="admin", password="secret", max_retries=3
        )

        mock_auth_cls.assert_called_once_with(username="admin", password="secret")
        mock_cluster_cls.assert_called_once_with(["localhost"], port=9042, auth_provider=mock_auth)
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
    @patch("cassandra_writer.KAFKA_PASSWORD", "secret")
    @patch("cassandra_writer.KAFKA_USERNAME", "testuser")
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_consumer_uses_sasl_when_credentials_set(self, mock_consumer_cls, mock_connect):
        mock_session = MagicMock()
        mock_cluster = MagicMock()
        mock_connect.return_value = (mock_cluster, mock_session)

        consumer_instance = mock_consumer_cls.return_value
        consumer_instance.poll.side_effect = lambda t: setattr(_mod, "_shutdown", True) or None

        _mod._shutdown = False
        _mod.consume_and_store()

        config = mock_consumer_cls.call_args[0][0]
        assert config["security.protocol"] == "SASL_PLAINTEXT"
        assert config["sasl.mechanism"] == "SCRAM-SHA-512"
        assert config["sasl.username"] == "testuser"
        assert config["sasl.password"] == "secret"
        _mod._shutdown = False

    @patch("cassandra_writer.KAFKA_PASSWORD", "")
    @patch("cassandra_writer.KAFKA_USERNAME", "")
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_consumer_no_sasl_without_credentials(self, mock_consumer_cls, mock_connect):
        mock_session = MagicMock()
        mock_cluster = MagicMock()
        mock_connect.return_value = (mock_cluster, mock_session)

        consumer_instance = mock_consumer_cls.return_value
        consumer_instance.poll.side_effect = lambda t: setattr(_mod, "_shutdown", True) or None

        _mod._shutdown = False
        _mod.consume_and_store()

        config = mock_consumer_cls.call_args[0][0]
        assert "security.protocol" not in config
        assert "sasl.mechanism" not in config
        _mod._shutdown = False

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
        msg.topic.return_value = "testorg.testproject.testcollection"
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

        _mod.consume_and_store()

        mock_session.prepare.assert_called_once()
        # session.execute also serves the schema introspection query, so assert on
        # the insert that uses the prepared statement specifically.
        insert_calls = [
            call for call in mock_session.execute.call_args_list if call.args[0] is prepared_stmt
        ]
        assert len(insert_calls) == 1
        values = insert_calls[0].args[1]
        assert 22.5 in values
        assert "sensor_001" in values
        consumer_instance.commit.assert_called_once()

        _mod._shutdown = False


def _make_message(topic, value, key=None):
    msg = MagicMock()
    msg.error.return_value = None
    msg.topic.return_value = topic
    msg.value.return_value = value
    msg.key.return_value = key
    return msg


def _column_rows(*names):
    rows = []
    for name in names:
        row = MagicMock()
        row.column_name = name
        rows.append(row)
    return rows


def _parsed_columns(query):
    """Return the column names of an INSERT statement, in order."""
    inner = query.split("(", 1)[1].split(")", 1)[0]
    return [col.strip() for col in inner.split(",")]


def _schema_aware_execute(table_columns, insert_calls):
    """Fake session.execute: answers system_schema reads, records INSERTs."""

    def execute(statement, *args):
        if isinstance(statement, str) and "system_schema.columns" in statement:
            return _column_rows(*table_columns)
        insert_calls.append((statement, args))
        return None

    return execute


def _run_consumer(mock_consumer_cls, messages):
    consumer_instance = mock_consumer_cls.return_value
    responses = list(messages)

    def poll(timeout):
        if responses:
            return responses.pop(0)
        _mod._shutdown = True
        return None

    consumer_instance.poll.side_effect = poll
    _mod._shutdown = False
    try:
        _mod.consume_and_store()
    finally:
        _mod._shutdown = False
    return consumer_instance


@pytest.fixture(autouse=True)
def _clear_table_columns_cache():
    cache = getattr(_mod, "_table_columns_cache", None)
    if cache is not None:
        cache.clear()
    yield


class TestFlattenMessage:
    def test_dict_payload_fields_are_hoisted(self):
        flat = _mod._flatten_message(
            {
                "mqtt_topic": "org/project/collection",
                "payload": {"temperature": 22.5, "humidity": 60},
                "ts": 1700000000000,
                "client_id": "mqtt-bridge",
            }
        )

        assert flat["temperature"] == 22.5
        assert flat["humidity"] == 60
        assert "payload" not in flat
        assert flat["mqtt_topic"] == "org/project/collection"
        assert flat["client_id"] == "mqtt-bridge"

    def test_payload_fields_win_over_envelope_metadata(self):
        flat = _mod._flatten_message({"mqtt_topic": "t", "payload": {"ts": 99}, "ts": 1})

        assert flat["ts"] == 99

    def test_string_payload_is_left_untouched(self):
        data = {"mqtt_topic": "t", "payload": "raw-string", "ts": 1}

        assert _mod._flatten_message(data) == data

    def test_hex_payload_is_left_untouched(self):
        data = {"mqtt_topic": "t", "payload": "00ff", "ts": 1}

        assert _mod._flatten_message(data) == data


class TestTableColumns:
    def test_parses_column_name_from_system_schema(self):
        session = MagicMock()
        session.execute.return_value = _column_rows("key", "timestamp", "temperature")

        columns = _mod._table_columns(session, "orgx", "tabx")

        assert columns == {"key", "timestamp", "temperature"}
        statement, params = session.execute.call_args[0]
        assert "system_schema.columns" in statement
        assert params == ("orgx", "tabx")

    def test_caches_columns_per_keyspace_and_table(self):
        session = MagicMock()
        session.execute.return_value = _column_rows("key", "temperature")

        first = _mod._table_columns(session, "orgy", "taby")
        second = _mod._table_columns(session, "orgy", "taby")

        assert first == second == {"key", "temperature"}
        assert session.execute.call_count == 1

    def test_returns_none_on_query_error(self):
        session = MagicMock()
        session.execute.side_effect = RuntimeError("system_schema unavailable")

        assert _mod._table_columns(session, "orgz", "tabz") is None

    def test_returns_none_when_table_has_no_columns(self):
        session = MagicMock()
        session.execute.return_value = []

        assert _mod._table_columns(session, "orgw", "tabw") is None

    def test_cache_expires_after_ttl(self, monkeypatch):
        session = MagicMock()
        session.execute.return_value = _column_rows("key", "temperature")
        now = [1000.0]
        monkeypatch.setattr(_mod.time, "monotonic", lambda: now[0])

        _mod._table_columns(session, "orgt", "tabt")
        now[0] += _mod._TABLE_COLUMNS_TTL - 1
        _mod._table_columns(session, "orgt", "tabt")
        assert session.execute.call_count == 1

        now[0] += 2
        _mod._table_columns(session, "orgt", "tabt")
        assert session.execute.call_count == 2


class TestEnvelopePersistence:
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_envelope_payload_is_written_to_table_columns(self, mock_consumer_cls, mock_connect):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(
            ["key", "timestamp", "temperature", "humidity"], insert_calls
        )
        mock_connect.return_value = (MagicMock(), session)

        envelope = {
            "mqtt_topic": "org1/proj1/coll1",
            "payload": {
                "key": "sensor-1",
                "timestamp": "2026-01-01T00:00:00+00:00",
                "temperature": 22.5,
                "humidity": 60,
            },
            "ts": 1700000000000,
            "client_id": "mqtt-bridge",
        }
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"), key=None)
        consumer_instance = _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        assert set(_parsed_columns(query)) == {"key", "timestamp", "temperature", "humidity"}
        assert "mqtt_topic" not in query
        assert "client_id" not in query
        assert "payload" not in query

        assert len(insert_calls) == 1
        statement, args = insert_calls[0]
        assert statement is prepared
        values = dict(zip(_parsed_columns(query), args[0]))
        assert values == {
            "key": "sensor-1",
            "timestamp": "2026-01-01T00:00:00+00:00",
            "temperature": 22.5,
            "humidity": 60,
        }
        consumer_instance.commit.assert_called_once()

    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_none_kafka_key_preserves_payload_key(self, mock_consumer_cls, mock_connect):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(["key", "temperature"], insert_calls)
        mock_connect.return_value = (MagicMock(), session)

        envelope = {"mqtt_topic": "t", "payload": {"key": "sensor-1", "temperature": 1}}
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"), key=None)
        _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        values = dict(zip(_parsed_columns(query), insert_calls[0][1][0]))
        assert values["key"] == "sensor-1"

    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_kafka_key_wins_over_payload_key(self, mock_consumer_cls, mock_connect):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(["key", "temperature"], insert_calls)
        mock_connect.return_value = (MagicMock(), session)

        envelope = {"mqtt_topic": "t", "payload": {"key": "payload-key", "temperature": 1}}
        msg = _make_message(
            "org1.proj1.coll1", json.dumps(envelope).encode("utf-8"), key=b"kafka-key"
        )
        _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        values = dict(zip(_parsed_columns(query), insert_calls[0][1][0]))
        assert values["key"] == "kafka-key"

    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_no_matching_columns_skips_without_crashing(self, mock_consumer_cls, mock_connect):
        session = MagicMock()
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(["reading"], insert_calls)
        mock_connect.return_value = (MagicMock(), session)

        envelope = {"mqtt_topic": "t", "payload": "raw-string", "ts": 1, "client_id": "c"}
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"))
        consumer_instance = _run_consumer(mock_consumer_cls, [msg])

        session.prepare.assert_not_called()
        assert insert_calls == []
        consumer_instance.commit.assert_called_once()

    @patch("cassandra_writer._table_columns", return_value=None)
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_unknown_table_columns_falls_back_to_all_keys(
        self, mock_consumer_cls, mock_connect, _mock_table_columns
    ):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        mock_connect.return_value = (MagicMock(), session)

        envelope = {
            "mqtt_topic": "t",
            "payload": {"temperature": 22.5},
            "ts": 1700000000000,
            "client_id": "mqtt-bridge",
        }
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"))
        _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        assert set(_parsed_columns(query)) == {"temperature", "timestamp", "day", "id"}
        session.execute.assert_called_once()
        assert session.execute.call_args.args[0] is prepared
        assert 22.5 in session.execute.call_args.args[1]


class TestNormalizeMessage:
    def test_bridge_envelope_produces_rest_shaped_document(self):
        doc = _mod._normalize_message(
            {
                "mqtt_topic": "org/project/collection",
                "payload": {
                    "key": "sensor-1",
                    "timestamp": "2026-01-01T10:00:00Z",
                    "temperature": 22.5,
                },
                "ts": 1700000000000,
                "client_id": "mqtt-bridge",
            },
            kafka_key=None,
        )

        assert doc["key"] == "sensor-1"
        assert doc["temperature"] == 22.5
        assert doc["timestamp"] == "2026-01-01T10:00:00Z"
        assert doc["day"] == "2026-01-01"
        assert uuid.UUID(doc["id"]).version == 4
        for banned in ("mqtt_topic", "payload", "client_id", "ts"):
            assert banned not in doc

    def test_missing_timestamp_is_current_utc_iso(self):
        doc = _mod._normalize_message({"payload": {"temperature": 1}}, kafka_key=None)

        assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", doc["timestamp"])
        assert doc["day"] == doc["timestamp"][:10]

    def test_day_is_derived_from_timestamp_in_utc(self):
        doc = _mod._normalize_message({"payload": {"timestamp": "2026-03-04T23:59:59Z"}}, None)

        assert doc["day"] == "2026-03-04"

    def test_payload_day_and_id_are_preserved(self):
        doc = _mod._normalize_message(
            {"payload": {"day": "2025-12-31", "id": "11111111-1111-4111-8111-111111111111"}},
            None,
        )

        assert doc["day"] == "2025-12-31"
        assert doc["id"] == "11111111-1111-4111-8111-111111111111"

    def test_kafka_key_only_overrides_when_present(self):
        doc = _mod._normalize_message({"payload": {"key": "payload-key"}}, "kafka-key")

        assert doc["key"] == "kafka-key"


class TestCoerceValueDate:
    @staticmethod
    def _date_type():
        cql_type = MagicMock()
        cql_type.typename = "date"
        return cql_type

    def test_date_string_becomes_date(self):
        assert _mod._coerce_value("2026-01-01", self._date_type()) == date(2026, 1, 1)

    def test_malformed_date_is_left_untouched(self):
        assert _mod._coerce_value("01/01/2026", self._date_type()) == "01/01/2026"


class TestRestPathRegression:
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_rest_style_message_inserts_unchanged(self, mock_consumer_cls, mock_connect):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(
            ["day", "key", "timestamp", "id", "temperature"], insert_calls
        )
        mock_connect.return_value = (MagicMock(), session)

        value = {
            "temperature": 21.0,
            "timestamp": "2026-02-03T04:05:06Z",
            "day": "2026-02-03",
            "id": "22222222-2222-4222-8222-222222222222",
        }
        msg = _make_message("org1.proj1.coll1", json.dumps(value).encode("utf-8"), key=b"rest-key")
        _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        assert set(_parsed_columns(query)) == {
            "day",
            "key",
            "timestamp",
            "id",
            "temperature",
        }
        assert len(insert_calls) == 1
        values = dict(zip(_parsed_columns(query), insert_calls[0][1][0]))
        assert values == {"key": "rest-key", **value}


class TestEnvelopeEdgeGuards:
    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_no_match_warning_names_topic_and_dropped_keys(
        self, mock_consumer_cls, mock_connect, caplog
    ):
        session = MagicMock()
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(["reading"], insert_calls)
        mock_connect.return_value = (MagicMock(), session)

        envelope = {
            "mqtt_topic": "org1/proj1/coll1",
            "payload": "raw-string",
            "ts": 1700000000000,
            "client_id": "mqtt-bridge",
        }
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"))
        with caplog.at_level(logging.WARNING, logger="cassandra_writer"):
            consumer_instance = _run_consumer(mock_consumer_cls, [msg])

        assert "org1.proj1.coll1" in caplog.text
        for dropped in ("mqtt_topic", "payload", "ts", "client_id"):
            assert dropped in caplog.text
        assert insert_calls == []
        consumer_instance.commit.assert_called_once()

    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_scalar_payload_is_not_inserted_when_table_lacks_payload_column(
        self, mock_consumer_cls, mock_connect
    ):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(
            ["key", "timestamp", "day", "id", "reading"], insert_calls
        )
        mock_connect.return_value = (MagicMock(), session)

        envelope = {"mqtt_topic": "t", "payload": "raw-string", "ts": 1, "client_id": "c"}
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"))
        _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        assert "payload" not in _parsed_columns(query)
        assert set(_parsed_columns(query)) == {"timestamp", "day", "id"}
        assert len(insert_calls) == 1

    @patch("cassandra_writer._connect_cassandra")
    @patch("cassandra_writer.Consumer")
    def test_scalar_payload_is_inserted_when_table_has_payload_column(
        self, mock_consumer_cls, mock_connect
    ):
        session = MagicMock()
        prepared = MagicMock()
        prepared.column_metadata = []
        session.prepare.return_value = prepared
        insert_calls = []
        session.execute.side_effect = _schema_aware_execute(["payload"], insert_calls)
        mock_connect.return_value = (MagicMock(), session)

        envelope = {"mqtt_topic": "t", "payload": "raw-string", "ts": 1, "client_id": "c"}
        msg = _make_message("org1.proj1.coll1", json.dumps(envelope).encode("utf-8"))
        _run_consumer(mock_consumer_cls, [msg])

        query = session.prepare.call_args[0][0]
        assert _parsed_columns(query) == ["payload"]
        assert insert_calls[0][1][0] == ["raw-string"]
