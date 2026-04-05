import asyncio
import hashlib
import json
import logging
import os
import queue
import signal
import threading
import time
import uuid

import aiocoap
import aiocoap.resource as resource
from aiocoap.numbers.codes import Code
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster
from confluent_kafka import KafkaException, Producer
from flask import Flask

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────────────

COAP_HOST = os.getenv("COAP_HOST", "::")
COAP_PORT = int(os.getenv("COAP_PORT", "5683"))
HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8080"))
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_USERNAME = os.getenv("KAFKA_USERNAME", "")
KAFKA_PASSWORD = os.getenv("KAFKA_PASSWORD", "")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "PLAIN")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SASL_PLAINTEXT")
CASSANDRA_CONTACT_POINTS = os.getenv("CASSANDRA_CONTACT_POINTS", "localhost").split(",")
CASSANDRA_PORT = int(os.getenv("CASSANDRA_PORT", "9042"))
CASSANDRA_USERNAME = os.getenv("CASSANDRA_USERNAME", "")
CASSANDRA_PASSWORD = os.getenv("CASSANDRA_PASSWORD", "")
ORGANIZATION_ID = os.getenv("ORGANIZATION_ID", "")
MAX_PAYLOAD_BYTES = int(os.getenv("MAX_PAYLOAD_BYTES", "1024"))

# ── Global state ──────────────────────────────────────────────────────────────

_shutdown = False
_message_queue = queue.Queue()
_cassandra_session = None

# ── Cassandra auth ─────────────────────────────────────────────────────────────


def _connect_cassandra():
    global _cassandra_session
    kwargs = {}
    if CASSANDRA_USERNAME and CASSANDRA_PASSWORD:
        kwargs["auth_provider"] = PlainTextAuthProvider(CASSANDRA_USERNAME, CASSANDRA_PASSWORD)
    cluster = Cluster(CASSANDRA_CONTACT_POINTS, port=CASSANDRA_PORT, **kwargs)
    _cassandra_session = cluster.connect("metadata")
    logger.info("Connected to Cassandra at %s:%s", CASSANDRA_CONTACT_POINTS, CASSANDRA_PORT)


def _hash_key(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def _lookup_key(hashed):
    try:
        return _cassandra_session.execute(
            "SELECT project_id, key_type FROM api_keys WHERE api_key=%s LIMIT 1 ALLOW FILTERING",
            (hashed,),
        ).one()
    except Exception as exc:
        logger.error("Cassandra error (key lookup): %s", exc)
        return None


def _lookup_org(org_id):
    try:
        return _cassandra_session.execute(
            "SELECT organization_name FROM organization WHERE id=%s LIMIT 1",
            (org_id,),
        ).one()
    except Exception as exc:
        logger.error("Cassandra error (org lookup): %s", exc)
        return None


def _lookup_project(project_id, org_id):
    try:
        return _cassandra_session.execute(
            "SELECT project_name FROM project "
            "WHERE id=%s AND organization_id=%s LIMIT 1 ALLOW FILTERING",
            (project_id, org_id),
        ).one()
    except Exception as exc:
        logger.error("Cassandra error (project lookup): %s", exc)
        return None


def _authenticate(raw_key, org_segment, project_segment):
    """Validate API key and ACL. Returns project_id string on success, None on failure."""
    # Step 1: key lookup — must be write or master type
    row = _lookup_key(_hash_key(raw_key))
    if row is None or row.key_type not in ("write", "master"):
        logger.debug("CoAP auth denied: key not found or insufficient type")
        return None

    # Step 2: resolve org UUID and validate org name against URI segment
    try:
        org_id = uuid.UUID(ORGANIZATION_ID)
    except ValueError:
        logger.error("ORGANIZATION_ID is not a valid UUID: %s", ORGANIZATION_ID)
        return None

    org = _lookup_org(org_id)
    if org is None or org.organization_name != org_segment:
        logger.debug("CoAP ACL denied: org segment %r does not match", org_segment)
        return None

    # Step 3: validate project name against URI segment
    project = _lookup_project(row.project_id, org_id)
    if project is None or project.project_name != project_segment:
        logger.debug("CoAP ACL denied: project segment %r does not match", project_segment)
        return None

    return str(row.project_id)


# ── Kafka producer ─────────────────────────────────────────────────────────────


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


def _build_envelope(coap_path, raw_payload, project_id):
    try:
        payload = json.loads(raw_payload.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        logger.warning("Non-JSON payload on path %s, wrapping as string", coap_path)
        try:
            payload = raw_payload.decode("utf-8")
        except UnicodeDecodeError:
            payload = raw_payload.hex()
    return {
        "coap_path": coap_path,
        "payload": payload,
        "ts": int(time.time() * 1000),
        "client_id": project_id,
    }


# ── CoAP resource tree ─────────────────────────────────────────────────────────


class _IngestResource(resource.Resource, resource.PathCapable):
    """PathCapable resource that handles POST /{org}/{project}/{collection}?key=<api_key>.

    BridgeSite.get_child consumes the first path segment and creates this resource,
    which then receives the remaining path in request.opt.uri_path.
    """

    def __init__(self, first_segment, loop):
        super().__init__()
        self._first = first_segment
        self._loop = loop

    async def render(self, request):
        if request.code != aiocoap.POST:
            return aiocoap.Message(code=Code.METHOD_NOT_ALLOWED)

        # Reconstruct full path — Site consumed first_segment, rest is in uri_path
        remaining = request.opt.uri_path or ()
        path = (self._first,) + remaining

        if len(path) != 3 or any(not p for p in path):
            return aiocoap.Message(
                code=Code.BAD_REQUEST,
                payload=b"URI must be exactly /{org}/{project}/{collection}",
            )

        org, project, collection = path

        # Enforce payload size limit before any auth work
        if len(request.payload) > MAX_PAYLOAD_BYTES:
            return aiocoap.Message(
                code=Code.REQUEST_ENTITY_TOO_LARGE,
                payload=b"Payload exceeds maximum allowed size",
            )

        # Extract API key from URI query string: ?key=<value>
        raw_key = None
        for q in request.opt.uri_query or ():
            if q.startswith("key="):
                raw_key = q[4:]
                break
        if not raw_key:
            return aiocoap.Message(
                code=Code.UNAUTHORIZED,
                payload=b"Missing ?key= query parameter",
            )

        # Authenticate + ACL check (blocking Cassandra → thread pool executor)
        project_id = await self._loop.run_in_executor(None, _authenticate, raw_key, org, project)
        if project_id is None:
            logger.info("CoAP auth denied for /%s/%s/%s", org, project, collection)
            return aiocoap.Message(code=Code.UNAUTHORIZED, payload=b"Unauthorized")

        # Build envelope and enqueue for Kafka producer thread
        coap_path = f"{org}/{project}/{collection}"
        kafka_topic = f"{org}.{project}.{collection}"
        envelope = _build_envelope(coap_path, request.payload, project_id)
        _message_queue.put((kafka_topic, json.dumps(envelope).encode("utf-8")))

        logger.info("CoAP POST accepted: %s → %s", coap_path, kafka_topic)
        return aiocoap.Message(code=Code.CHANGED)


class BridgeSite(resource.Site):
    """Site that routes any first path segment to the ingest resource as a fallback."""

    def __init__(self, loop):
        super().__init__()
        self._loop = loop
        self.add_resource(
            [".well-known", "core"],
            resource.WKCResource(self.get_resources_as_linkheader),
        )

    def get_child(self, name, request):
        try:
            return super().get_child(name, request)
        except Exception:
            # Any unregistered path segment is routed to the ingest resource
            return _IngestResource(name, self._loop)


# ── HTTP health endpoint ───────────────────────────────────────────────────────

_health_app = Flask("coap-bridge-health")


@_health_app.get("/health")
def health():
    return {"status": "ok"}, 200


def _run_health_server():
    import logging as _log

    _log.getLogger("werkzeug").setLevel(_log.WARNING)
    _health_app.run(host="0.0.0.0", port=HEALTH_PORT, threaded=True)


# ── Main ───────────────────────────────────────────────────────────────────────


async def _run_server():
    loop = asyncio.get_running_loop()
    site = BridgeSite(loop)
    context = await aiocoap.Context.create_server_context(site, bind=(COAP_HOST, COAP_PORT))
    logger.info("CoAP server listening on %s:%s (UDP)", COAP_HOST or "[::]", COAP_PORT)

    stop = loop.create_future()

    def _on_signal():
        global _shutdown
        logger.info("Shutdown signal received")
        _shutdown = True
        if not stop.done():
            stop.set_result(None)

    loop.add_signal_handler(signal.SIGTERM, _on_signal)
    loop.add_signal_handler(signal.SIGINT, _on_signal)

    await stop
    logger.info("Stopping CoAP context...")
    await context.shutdown()


def main():
    _connect_cassandra()

    producer = _build_producer()
    producer_thread = threading.Thread(target=_run_producer, args=(producer,), daemon=True)
    producer_thread.start()
    logger.info("Kafka producer thread started")

    health_thread = threading.Thread(target=_run_health_server, daemon=True)
    health_thread.start()
    logger.info("HTTP health server started on port %s", HEALTH_PORT)

    try:
        asyncio.run(_run_server())
    finally:
        logger.info("Waiting for producer thread to drain queue...")
        producer_thread.join(timeout=10)
        logger.info("Flushing Kafka producer...")
        producer.flush(10)
        logger.info("Shutdown complete")


if __name__ == "__main__":
    main()
