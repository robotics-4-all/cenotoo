import json
import logging
import os
import re
import signal
import time
import uuid
from datetime import datetime, timezone

from cassandra import InvalidRequest
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster
from confluent_kafka import Consumer, KafkaError, KafkaException

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# Kafka and Cassandra configurations from environment variables
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_USERNAME = os.getenv("KAFKA_USERNAME", "")
KAFKA_PASSWORD = os.getenv("KAFKA_PASSWORD", "")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "SCRAM-SHA-512")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
KAFKA_CONSUMER_GROUP = os.getenv("KAFKA_CONSUMER_GROUP", "cenotoo_cassandra_writer")
CASSANDRA_CONTACT_POINTS = [os.getenv("CASSANDRA_CONTACT_POINTS", "localhost")]
CASSANDRA_PORT = int(os.getenv("CASSANDRA_PORT", "9042"))
CASSANDRA_USERNAME = os.getenv("CASSANDRA_USERNAME", "")
CASSANDRA_PASSWORD = os.getenv("CASSANDRA_PASSWORD", "")

# Regex pattern to subscribe to all org.project.collection topics
TOPIC_PATTERN = "^[a-zA-Z_][a-zA-Z0-9_]*\\.[a-zA-Z_][a-zA-Z0-9_]*\\.[a-zA-Z_][a-zA-Z0-9_]*$"

# Valid CQL identifier pattern (alphanumeric + underscore only)
_VALID_IDENTIFIER = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")

_shutdown = False


def _signal_handler(signum, frame):
    global _shutdown
    logger.info("Received signal %s, shutting down gracefully...", signum)
    _shutdown = True


signal.signal(signal.SIGTERM, _signal_handler)
signal.signal(signal.SIGINT, _signal_handler)


def _coerce_value(value, cql_type):
    if value is None or cql_type is None:
        return value
    if isinstance(value, str):
        type_name = getattr(cql_type, "typename", "")
        if type_name == "timestamp":
            try:
                return datetime.fromisoformat(value.replace("Z", "+00:00"))
            except (ValueError, AttributeError):
                pass
        elif type_name in ("uuid", "timeuuid"):
            try:
                return uuid.UUID(value)
            except (ValueError, AttributeError):
                pass
        elif type_name == "date":
            try:
                return datetime.strptime(value, "%Y-%m-%d").date()
            except (ValueError, AttributeError):
                pass
    return value


def _validate_identifier(name):
    """Validate that a CQL identifier contains only safe characters."""
    if not _VALID_IDENTIFIER.match(name):
        raise ValueError(
            f"Invalid CQL identifier: {name!r}. "
            "Only alphanumeric characters and underscores are allowed."
        )
    return name


# Envelope metadata added by the MQTT/CoAP bridges; never a table column.
# A scalar "payload" is left in place: the column filter drops it unless the
# table really has a payload column.
_ENVELOPE_ONLY_KEYS = ("mqtt_topic", "client_id", "ts")

# How long (seconds) a cached system_schema.columns lookup stays valid, so that
# schema changes made through the API (PATCH /schema) are picked up.
_TABLE_COLUMNS_TTL = int(os.getenv("CASSANDRA_COLUMNS_TTL", "300"))


def _timestamp_to_day(value):
    """Return the UTC date (YYYY-MM-DD) of an ISO-8601 timestamp."""
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return datetime.now(timezone.utc).date().isoformat()

    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc)
    return parsed.date().isoformat()


def _normalize_message(message_data, kafka_key=None):
    """Shape bridge envelopes like the REST /send_data documents the API produces.

    The payload is flattened, bridge metadata is dropped, and the primary key
    columns (key, timestamp, day, id) are guaranteed to exist. Without them an
    INSERT into an API-created collection table is rejected as a schema mismatch.
    """
    document = dict(_flatten_message(message_data))

    if kafka_key is not None:
        document["key"] = kafka_key
    for name in _ENVELOPE_ONLY_KEYS:
        document.pop(name, None)

    if not document.get("timestamp"):
        document["timestamp"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not document.get("day"):
        document["day"] = _timestamp_to_day(document["timestamp"])
    if not document.get("id"):
        document["id"] = str(uuid.uuid4())

    return document


# Cache of table column names keyed by (keyspace, table)
_table_columns_cache = {}


def _flatten_message(message_data):
    """Hoist a dict payload onto the top level so bridge envelopes map to table columns.

    Scalar payloads (raw strings, hex dumps) are left in place: they cannot map to
    a table column and are dropped later by the column filter.
    """
    payload = message_data.get("payload")
    if not isinstance(payload, dict):
        return message_data

    flattened = {name: value for name, value in message_data.items() if name != "payload"}
    flattened.update(payload)
    return flattened


def _table_columns(session, keyspace, table):
    """Return the real column names of keyspace.table, or None when unknown.

    None means the lookup failed (or the table is not there yet) and the caller
    should fall back to using the message keys as-is.
    """
    cache_key = (keyspace, table)
    cached = _table_columns_cache.get(cache_key)
    if cached is not None:
        cached_columns, fetched_at = cached
        if time.monotonic() - fetched_at < _TABLE_COLUMNS_TTL:
            return cached_columns

    query = "SELECT column_name FROM system_schema.columns WHERE keyspace_name=%s AND table_name=%s"
    try:
        rows = session.execute(query, (keyspace, table))
        columns = {row.column_name for row in rows}
    except Exception as exc:
        logger.warning(
            "Could not read columns for %s.%s: %s — falling back to message keys",
            keyspace,
            table,
            exc,
        )
        return None

    if not columns:
        logger.warning("No columns found for %s.%s — falling back to message keys", keyspace, table)
        return None

    _table_columns_cache[cache_key] = (columns, time.monotonic())
    return columns


def _connect_cassandra(contact_points, port, username="", password="", max_retries=5):
    auth_provider = None
    if username and password:
        auth_provider = PlainTextAuthProvider(username=username, password=password)

    for attempt in range(1, max_retries + 1):
        try:
            cluster = Cluster(contact_points, port=port, auth_provider=auth_provider)
            session = cluster.connect()
            logger.info("Connected to Cassandra (attempt %d/%d)", attempt, max_retries)
            return cluster, session
        except Exception:
            logger.warning(
                "Cassandra connection failed (attempt %d/%d)",
                attempt,
                max_retries,
                exc_info=True,
            )
            if attempt == max_retries:
                raise
            time.sleep(min(2**attempt, 30))
    # unreachable, but satisfies type checker
    raise RuntimeError("Failed to connect to Cassandra")


def consume_and_store():
    cluster, session = _connect_cassandra(
        CASSANDRA_CONTACT_POINTS, CASSANDRA_PORT, CASSANDRA_USERNAME, CASSANDRA_PASSWORD
    )

    # Cache for prepared statements keyed by (keyspace, table, frozenset of column names)
    prepared_cache = {}

    consumer_config = {
        "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
        "group.id": KAFKA_CONSUMER_GROUP,
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,
    }
    if KAFKA_USERNAME and KAFKA_PASSWORD:
        consumer_config.update(
            {
                "security.protocol": KAFKA_SECURITY_PROTOCOL,
                "sasl.mechanism": KAFKA_SASL_MECHANISM,
                "sasl.username": KAFKA_USERNAME,
                "sasl.password": KAFKA_PASSWORD,
            }
        )

    consumer = Consumer(consumer_config)

    consumer.subscribe([TOPIC_PATTERN])
    logger.info("Subscribed to topic pattern: %s", TOPIC_PATTERN)

    _logged_no_topics = False

    try:
        while not _shutdown:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                err_code = msg.error().code()
                if err_code == KafkaError._PARTITION_EOF:
                    continue
                # On a fresh install no topics match TOPIC_PATTERN yet; broker
                # responds with UNKNOWN_TOPIC_OR_PART on every poll until the
                # first producer publishes. Treat it as benign — log once,
                # then keep polling. Topics auto-create when MQTT/CoAP/REST
                # produces a message and the regex subscription picks them up.
                if err_code == KafkaError.UNKNOWN_TOPIC_OR_PART:
                    if not _logged_no_topics:
                        logger.info(
                            "No Kafka topics match %s yet — waiting for first producer",
                            TOPIC_PATTERN,
                        )
                        _logged_no_topics = True
                    time.sleep(5)
                    continue
                raise KafkaException(msg.error())

            topic = msg.topic()
            parts = topic.split(".")
            if len(parts) != 3:
                logger.warning("Skipping message from unexpected topic format: %s", topic)
                consumer.commit(message=msg, asynchronous=False)
                continue

            org, project, collection = parts
            try:
                keyspace_name = _validate_identifier(org)
                table_name = _validate_identifier(f"{project}_{collection}")
            except ValueError as exc:
                logger.warning("Skipping message — invalid identifiers in topic %s: %s", topic, exc)
                consumer.commit(message=msg, asynchronous=False)
                continue

            raw_data = json.loads(msg.value().decode("utf-8"))
            flattened_keys = list(_flatten_message(raw_data))
            # Only a real Kafka key overrides the payload's primary key field
            kafka_key = msg.key().decode("utf-8") if msg.key() is not None else None
            message_data = _normalize_message(raw_data, kafka_key)

            table_columns = _table_columns(session, keyspace_name, table_name)
            if table_columns is not None:
                candidate_keys = list(dict.fromkeys(flattened_keys + list(message_data)))
                skipped = [name for name in candidate_keys if name not in table_columns]
                message_data = {
                    name: value for name, value in message_data.items() if name in table_columns
                }
                if not message_data:
                    logger.warning(
                        "Skipping message — no columns of %s.%s match topic %s keys: %s",
                        keyspace_name,
                        table_name,
                        topic,
                        skipped,
                    )
                    consumer.commit(message=msg, asynchronous=False)
                    continue

            columns = []
            invalid_column = None
            for col_name in message_data:
                try:
                    _validate_identifier(col_name)
                except ValueError as exc:
                    invalid_column = exc
                    break
                columns.append(col_name)
            if invalid_column is not None:
                logger.warning(
                    "Skipping message — invalid column for %s.%s: %s",
                    keyspace_name,
                    table_name,
                    invalid_column,
                )
                consumer.commit(message=msg, asynchronous=False)
                continue

            col_key = (keyspace_name, table_name, frozenset(columns))
            if col_key not in prepared_cache:
                col_str = ", ".join(columns)
                placeholders = ", ".join(["?"] * len(columns))
                query = (
                    f"INSERT INTO {keyspace_name}.{table_name} ({col_str}) VALUES ({placeholders})"
                )
                try:
                    prepared_cache[col_key] = session.prepare(query)
                except InvalidRequest as exc:
                    logger.warning(
                        "Skipping message — schema mismatch for %s.%s: %s",
                        keyspace_name,
                        table_name,
                        exc,
                    )
                    consumer.commit(message=msg, asynchronous=False)
                    continue
                logger.info(
                    "Prepared new statement for %s.%s columns: %s",
                    keyspace_name,
                    table_name,
                    columns,
                )

            prepared = prepared_cache[col_key]
            type_map = {meta[2]: meta[3] for meta in (prepared.column_metadata or [])}
            values = [_coerce_value(message_data[col], type_map.get(col)) for col in columns]
            try:
                session.execute(prepared, values)
            except TypeError as exc:
                logger.warning(
                    "Skipping message — type coercion failed for %s.%s: %s",
                    keyspace_name,
                    table_name,
                    exc,
                )
                consumer.commit(message=msg, asynchronous=False)
                continue

            # Commit offset after successful write
            consumer.commit(message=msg, asynchronous=False)

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
    finally:
        logger.info("Closing consumer and Cassandra connections...")
        consumer.close()
        session.shutdown()
        cluster.shutdown()
        logger.info("Shutdown complete")


if __name__ == "__main__":
    consume_and_store()
