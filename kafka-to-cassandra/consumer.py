import json
import logging
import os
import re
import signal
import time

from cassandra.cluster import Cluster
from confluent_kafka import Consumer, KafkaError, KafkaException

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# Kafka and Cassandra configurations from environment variables
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
CASSANDRA_CONTACT_POINTS = [os.getenv("CASSANDRA_CONTACT_POINTS", "localhost")]
CASSANDRA_PORT = int(os.getenv("CASSANDRA_PORT", "9042"))
COLLECTION_NAME = os.getenv("COLLECTION_NAME", "your_collection_name")
PROJECT_NAME = os.getenv("PROJECT_NAME", "your_project_name")
ORGANIZATION_NAME = os.getenv("ORGANIZATION_NAME", "your_organization_name")

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


def _connect_cassandra(contact_points, port, max_retries=5):
    for attempt in range(1, max_retries + 1):
        try:
            cluster = Cluster(contact_points, port=port)
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


def consume_and_store(topic_name, keyspace_name, table_name):
    _validate_identifier(keyspace_name)
    _validate_identifier(table_name)

    cluster, session = _connect_cassandra(CASSANDRA_CONTACT_POINTS, CASSANDRA_PORT)

    # Cache for prepared statements keyed by frozenset of column names
    prepared_cache = {}

    consumer = Consumer(
        {
            "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
            "group.id": f"{topic_name}_cassandra_writer",
            "auto.offset.reset": "earliest",
            "enable.auto.commit": False,
        }
    )

    consumer.subscribe([topic_name])
    logger.info("Subscribed to topic: %s", topic_name)

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

            message_data = json.loads(msg.value().decode("utf-8"))
            message_data["key"] = msg.key().decode("utf-8") if msg.key() else None

            columns = []
            for col_name in message_data:
                _validate_identifier(col_name)
                columns.append(col_name)

            col_key = frozenset(columns)
            if col_key not in prepared_cache:
                col_str = ", ".join(columns)
                placeholders = ", ".join(["%s"] * len(columns))
                query = (
                    f"INSERT INTO {keyspace_name}.{table_name} ({col_str}) VALUES ({placeholders})"
                )
                prepared_cache[col_key] = session.prepare(query)
                logger.info("Prepared new statement for columns: %s", columns)

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
    topic = f"{ORGANIZATION_NAME}.{PROJECT_NAME}.{COLLECTION_NAME}"
    table = f"{PROJECT_NAME}_{COLLECTION_NAME}"
    consume_and_store(topic, ORGANIZATION_NAME, table)
