import os
import signal
import logging

from confluent_kafka import Consumer, KafkaError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# Kafka configurations from environment variables
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
COLLECTION_NAME = os.getenv("COLLECTION_NAME", "your_collection_name")
PROJECT_NAME = os.getenv("PROJECT_NAME", "your_project_name")
ORGANIZATION_NAME = os.getenv("ORGANIZATION_NAME", "your_organization_name")
GROUP_ID = os.getenv("GROUP_ID", f"{PROJECT_NAME}.{COLLECTION_NAME}_live_group")

_shutdown = False


def _signal_handler(signum, frame):
    global _shutdown
    logger.info("Received signal %s, shutting down gracefully...", signum)
    _shutdown = True


signal.signal(signal.SIGTERM, _signal_handler)
signal.signal(signal.SIGINT, _signal_handler)


def get_kafka_consumer():
    return Consumer(
        {
            "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
            "group.id": GROUP_ID,
            "auto.offset.reset": "latest",
        }
    )


def consume_and_broadcast(consumer, topic):
    consumer.subscribe([topic])
    logger.info("Subscribed to topic: %s (group: %s)", topic, GROUP_ID)

    try:
        while not _shutdown:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                else:
                    logger.error("Kafka error: %s", msg.error())
            else:
                # Placeholder for broadcasting the message
                logger.info("Received message: %s", msg.value().decode("utf-8"))
    except KeyboardInterrupt:
        logger.info("Interrupted by user")
    finally:
        logger.info("Closing consumer...")
        consumer.close()
        logger.info("Shutdown complete")


if __name__ == "__main__":
    consumer = get_kafka_consumer()
    topic = f"{ORGANIZATION_NAME}.{PROJECT_NAME}.{COLLECTION_NAME}"
    consume_and_broadcast(consumer, topic)
