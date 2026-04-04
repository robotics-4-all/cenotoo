import json
import logging
import os
import re
import signal
import time

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


def _validate_identifier(name):
    """Validate that a CQL identifier contains only safe characters."""
    if not _VALID_IDENTIFIER.match(name):
        raise ValueError(
            f"Invalid CQL identifier: {name!r}. "
            "Only alphanumeric characters and underscores are allowed."
        )
    return name


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

    try:
        while not _shutdown:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                else:
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

            message_data = json.loads(msg.value().decode("utf-8"))
            message_data["key"] = msg.key().decode("utf-8") if msg.key() else None

            columns = []
            for col_name in message_data:
                _validate_identifier(col_name)
                columns.append(col_name)

            col_key = (keyspace_name, table_name, frozenset(columns))
            if col_key not in prepared_cache:
                col_str = ", ".join(columns)
                placeholders = ", ".join(["?"] * len(columns))
                query = (
                    f"INSERT INTO {keyspace_name}.{table_name} ({col_str}) VALUES ({placeholders})"
                )
                prepared_cache[col_key] = session.prepare(query)
                logger.info(
                    "Prepared new statement for %s.%s columns: %s",
                    keyspace_name,
                    table_name,
                    columns,
                )

            prepared = prepared_cache[col_key]
            values = [message_data[col] for col in columns]
            session.execute(prepared, values)

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
