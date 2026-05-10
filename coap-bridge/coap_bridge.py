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
import psycopg2
import psycopg2.extras
from aiocoap.numbers.codes import Code
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
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "localhost")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
POSTGRES_DB = os.getenv("POSTGRES_DB", "cenotoo")
POSTGRES_USER = os.getenv("POSTGRES_USER", "cenotoo")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "cenotoo")
MAX_PAYLOAD_BYTES = int(os.getenv("MAX_PAYLOAD_BYTES", "1024"))

# ── Global state ──────────────────────────────────────────────────────────────

_shutdown = False
_message_queue = queue.Queue()
_pg_conn = None

# ── PostgreSQL auth ────────────────────────────────────────────────────────────


def _connect_postgres():
    global _pg_conn
    _pg_conn = psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
    )
    logger.info("Connected to PostgreSQL at %s:%s", POSTGRES_HOST, POSTGRES_PORT)


def _hash_key(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def _lookup_key(hashed):
    try:
        with _pg_conn.cursor(cursor_factory=psycopg2.extras.NamedTupleCursor) as cur:
            cur.execute(
                "SELECT project_id, key_type FROM api_keys WHERE api_key=%s LIMIT 1",
                (hashed,),
            )
            return cur.fetchone()
    except Exception as exc:
        logger.error("PostgreSQL error (key lookup): %s", exc)
        return None


def _lookup_org(org_id):
    try:
        with _pg_conn.cursor(cursor_factory=psycopg2.extras.NamedTupleCursor) as cur:
            cur.execute(
                "SELECT organization_name FROM organization WHERE id=%s",
                (org_id,),
            )
            return cur.fetchone()
    except Exception as exc:
        logger.error("PostgreSQL error (org lookup): %s", exc)
        return None


def _lookup_project(project_id):
    try:
        with _pg_conn.cursor(cursor_factory=psycopg2.extras.NamedTupleCursor) as cur:
            cur.execute(
                "SELECT project_name, organization_id FROM project WHERE id=%s LIMIT 1",
                (project_id,),
            )
            return cur.fetchone()
    except Exception as exc:
        logger.error("PostgreSQL error (project lookup): %s", exc)
        return None


def _authenticate(raw_key, org_segment, project_segment):
    """Validate API key and ACL. Returns project_id string on success, None on failure.

    Resolves org and project entirely from the API key — no ORGANIZATION_ID env var needed.
    This makes the bridge multi-tenant: any org's devices can use it provided they have
    a valid write/master key and their URI segments match their registered names.
    """
    # Step 1: key lookup — must be write or master type
    row = _lookup_key(_hash_key(raw_key))
    if row is None or row.key_type not in ("write", "master"):
        logger.debug("CoAP auth denied: key not found or insufficient type")
        return None

    # Step 2: resolve project → get organization_id + project_name
    project = _lookup_project(row.project_id)
    if project is None:
        logger.debug("CoAP ACL denied: project %s not found", row.project_id)
        return None
    if project.project_name != project_segment:
        logger.debug("CoAP ACL denied: project segment %r does not match", project_segment)
        return None

    # Step 3: resolve org name and validate against URI segment
    org = _lookup_org(project.organization_id)
    if org is None or org.organization_name != org_segment:
        logger.debug("CoAP ACL denied: org segment %r does not match", org_segment)
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


async def _handle_ingest(request, loop):
    """Core ingestion handler — shared by BridgeSite.render and render_to_pipe."""
    if request.code != aiocoap.POST:
        return aiocoap.Message(code=Code.METHOD_NOT_ALLOWED)

    path = request.opt.uri_path or ()
    # Strip trailing empty segment produced by a trailing slash
    path = tuple(p for p in path if p)

    if len(path) != 3:
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
    project_id = await loop.run_in_executor(None, _authenticate, raw_key, org, project)
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
    """Site that routes /{org}/{project}/{collection} to the ingest handler.

    aiocoap's Site dispatches via _find_child_and_pathstripped_message which raises
    KeyError for unregistered paths — that KeyError is normally converted to
    error.NotFound in render/render_to_pipe. We intercept at that level so that
    any path not explicitly registered (i.e. not .well-known/core) falls through
    to _handle_ingest with the original request intact.
    """

    def __init__(self, loop):
        super().__init__()
        self._loop = loop
        self.add_resource(
            [".well-known", "core"],
            resource.WKCResource(self.get_resources_as_linkheader),
        )

    async def render(self, request):
        try:
            child, subrequest = self._find_child_and_pathstripped_message(request)
        except KeyError:
            return await _handle_ingest(request, self._loop)
        return await child.render(subrequest)

    async def render_to_pipe(self, request):
        try:
            child, subrequest = self._find_child_and_pathstripped_message(request.request)
        except KeyError:
            response = await _handle_ingest(request.request, self._loop)
            request.add_response(response)
            return
        request.request = subrequest
        return await child.render_to_pipe(request)


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
    _connect_postgres()

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
