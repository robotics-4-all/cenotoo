import json
import logging
import os
import queue
import signal
import threading
import time

import paho.mqtt.client as mqtt
from confluent_kafka import KafkaException, Producer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

MQTT_BROKER_HOST = os.getenv("MQTT_BROKER_HOST", "mosquitto")
MQTT_BROKER_PORT = int(os.getenv("MQTT_BROKER_PORT", "1883"))
MQTT_USERNAME = os.getenv("MQTT_USERNAME", "")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "")
MQTT_CLIENT_ID = os.getenv("MQTT_CLIENT_ID", "cenotoo-bridge")
MQTT_KEEPALIVE = int(os.getenv("MQTT_KEEPALIVE", "60"))
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_USERNAME = os.getenv("KAFKA_USERNAME", "")
KAFKA_PASSWORD = os.getenv("KAFKA_PASSWORD", "")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "PLAIN")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")

_shutdown = False
_message_queue = queue.Queue()


def _signal_handler(signum, frame):
    global _shutdown
    logger.info("Received signal %s, shutting down gracefully...", signum)
    _shutdown = True


signal.signal(signal.SIGTERM, _signal_handler)
signal.signal(signal.SIGINT, _signal_handler)


def _build_kafka_topic(mqtt_topic):
    parts = mqtt_topic.split("/")
    if len(parts) != 3 or any(not p for p in parts):
        return None
    return ".".join(parts)


def _build_envelope(mqtt_topic, raw_payload, client_id):
    try:
        payload = json.loads(raw_payload.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        logger.warning("Non-JSON payload on topic %s, wrapping as raw string", mqtt_topic)
        try:
            payload = raw_payload.decode("utf-8")
        except UnicodeDecodeError:
            payload = raw_payload.hex()
    return {
        "mqtt_topic": mqtt_topic,
        "payload": payload,
        "ts": int(time.time() * 1000),
        "client_id": client_id,
    }


def on_connect(client, userdata, flags, rc):
    if rc == 0:
        logger.info("Connected to MQTT broker at %s:%s", MQTT_BROKER_HOST, MQTT_BROKER_PORT)
        client.subscribe("#")
        logger.info("Subscribed to MQTT topic: #")
    else:
        logger.error("Failed to connect to MQTT broker, return code: %s", rc)


def on_disconnect(client, userdata, rc):
    if rc != 0:
        logger.warning("Unexpected MQTT disconnect, rc=%s", rc)
    else:
        logger.info("Disconnected from MQTT broker")


def on_message(client, userdata, msg):
    kafka_topic = _build_kafka_topic(msg.topic)
    if kafka_topic is None:
        logger.warning("Skipping invalid MQTT topic (expected exactly 3 segments): %s", msg.topic)
        return
    envelope = _build_envelope(msg.topic, msg.payload, MQTT_CLIENT_ID)
    _message_queue.put((kafka_topic, json.dumps(envelope).encode("utf-8")))


def _run_producer(producer):
    while not _shutdown or not _message_queue.empty():
        try:
            kafka_topic, value = _message_queue.get(timeout=1.0)
        except queue.Empty:
            producer.poll(0)
            continue
        try:
            producer.produce(kafka_topic, value)
            producer.poll(0)
        except BufferError:
            logger.warning("Kafka producer buffer full, dropping message on topic %s", kafka_topic)
        except KafkaException as exc:
            logger.error("Kafka produce error on topic %s: %s", kafka_topic, exc)
        _message_queue.task_done()


def _build_producer():
    config = {"bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS}
    if KAFKA_USERNAME and KAFKA_PASSWORD:
        config.update(
            {
                "security.protocol": KAFKA_SECURITY_PROTOCOL,
                "sasl.mechanism": KAFKA_SASL_MECHANISM,
                "sasl.username": KAFKA_USERNAME,
                "sasl.password": KAFKA_PASSWORD,
            }
        )
    return Producer(config)


def main():
    producer = _build_producer()
    producer_thread = threading.Thread(target=_run_producer, args=(producer,), daemon=True)
    producer_thread.start()
    logger.info("Kafka producer thread started")

    client = mqtt.Client(client_id=MQTT_CLIENT_ID)
    if MQTT_USERNAME and MQTT_PASSWORD:
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    try:
        client.connect(MQTT_BROKER_HOST, MQTT_BROKER_PORT, keepalive=MQTT_KEEPALIVE)
        client.loop_start()
        logger.info("MQTT loop started")

        while not _shutdown:
            time.sleep(0.5)

    except Exception:
        logger.exception("Fatal error in MQTT bridge")
    finally:
        logger.info("Stopping MQTT loop...")
        client.loop_stop()
        client.disconnect()
        logger.info("Waiting for producer thread to drain queue...")
        producer_thread.join(timeout=10)
        logger.info("Flushing Kafka producer...")
        producer.flush(10)
        logger.info("Shutdown complete")


if __name__ == "__main__":
    main()
