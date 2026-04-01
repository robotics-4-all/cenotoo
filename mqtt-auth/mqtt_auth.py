import hashlib
import logging
import os
import signal
import sys
import uuid

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster
from flask import Flask, request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

CASSANDRA_CONTACT_POINTS = os.getenv("CASSANDRA_CONTACT_POINTS", "localhost").split(",")
CASSANDRA_PORT = int(os.getenv("CASSANDRA_PORT", "9042"))
CASSANDRA_USERNAME = os.getenv("CASSANDRA_USERNAME", "")
CASSANDRA_PASSWORD = os.getenv("CASSANDRA_PASSWORD", "")
ORGANIZATION_ID = os.getenv("ORGANIZATION_ID", "")
MQTT_BRIDGE_USERNAME = os.getenv("MQTT_BRIDGE_USERNAME", "cenotoo-bridge")
MQTT_BRIDGE_PASSWORD = os.getenv("MQTT_BRIDGE_PASSWORD", "")

app = Flask(__name__)
_session = None


def _connect():
    global _session
    kwargs = {}
    if CASSANDRA_USERNAME and CASSANDRA_PASSWORD:
        kwargs["auth_provider"] = PlainTextAuthProvider(CASSANDRA_USERNAME, CASSANDRA_PASSWORD)
    cluster = Cluster(CASSANDRA_CONTACT_POINTS, port=CASSANDRA_PORT, **kwargs)
    _session = cluster.connect("metadata")
    logger.info("Connected to Cassandra at %s:%s", CASSANDRA_CONTACT_POINTS, CASSANDRA_PORT)


def _hash_key(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def _lookup_key(hashed, project_id):
    try:
        return _session.execute(
            "SELECT key_type FROM api_keys "
            "WHERE api_key=%s AND project_id=%s LIMIT 1 ALLOW FILTERING",
            (hashed, project_id),
        ).one()
    except Exception as e:
        logger.error("Cassandra error (key lookup): %s", e)
        return None


def _lookup_org(org_id):
    try:
        return _session.execute(
            "SELECT organization_name FROM organization WHERE id=%s LIMIT 1",
            (org_id,),
        ).one()
    except Exception as e:
        logger.error("Cassandra error (org lookup): %s", e)
        return None


def _lookup_project(project_id, org_id):
    try:
        return _session.execute(
            "SELECT project_name FROM project "
            "WHERE id=%s AND organization_id=%s LIMIT 1 ALLOW FILTERING",
            (project_id, org_id),
        ).one()
    except Exception as e:
        logger.error("Cassandra error (project lookup): %s", e)
        return None


@app.get("/health")
def health():
    return {"status": "ok"}, 200


@app.post("/auth/user")
def auth_user():
    data = request.get_json(force=True, silent=True) or {}
    username = data.get("username", "")
    password = data.get("password", "")

    if username == MQTT_BRIDGE_USERNAME:
        if MQTT_BRIDGE_PASSWORD and password == MQTT_BRIDGE_PASSWORD:
            logger.info("MQTT auth allowed: bridge superuser")
            return {}, 200
        logger.info("MQTT auth denied: bad bridge credentials")
        return {}, 403

    try:
        project_id = uuid.UUID(username)
    except ValueError:
        logger.debug("MQTT auth denied: username is not a UUID: %s", username)
        return {}, 403

    row = _lookup_key(_hash_key(password), project_id)
    if row is None or row.key_type not in ("write", "master"):
        logger.info("MQTT auth denied: no valid key for project %s", project_id)
        return {}, 403

    logger.info("MQTT auth allowed: project %s", project_id)
    return {}, 200


@app.post("/auth/acl")
def auth_acl():
    data = request.get_json(force=True, silent=True) or {}
    username = data.get("username", "")
    topic = data.get("topic", "")
    acc = data.get("acc", 0)

    if username == MQTT_BRIDGE_USERNAME:
        return {}, 200

    if acc != 2:
        logger.debug("MQTT ACL denied: non-publish acc=%d topic=%s", acc, topic)
        return {}, 403

    parts = topic.split("/")
    if len(parts) != 3 or any(not p for p in parts):
        logger.debug("MQTT ACL denied: invalid topic format: %s", topic)
        return {}, 403

    org_segment, project_segment, _ = parts

    try:
        org_id = uuid.UUID(ORGANIZATION_ID)
    except ValueError:
        logger.error("MQTT ACL: ORGANIZATION_ID is not a valid UUID: %s", ORGANIZATION_ID)
        return {}, 403

    org = _lookup_org(org_id)
    if org is None or org.organization_name != org_segment:
        logger.debug("MQTT ACL denied: org segment '%s' does not match", org_segment)
        return {}, 403

    try:
        project_id = uuid.UUID(username)
    except ValueError:
        logger.debug("MQTT ACL denied: username is not a UUID: %s", username)
        return {}, 403

    project = _lookup_project(project_id, org_id)
    if project is None or project.project_name != project_segment:
        logger.debug("MQTT ACL denied: project segment '%s' does not match", project_segment)
        return {}, 403

    logger.info("MQTT ACL allowed: %s → %s", username, topic)
    return {}, 200


def _handle_signal(signum, frame):
    logger.info("Received signal %d, shutting down", signum)
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    _connect()
    app.run(host="0.0.0.0", port=8080, threaded=True)
