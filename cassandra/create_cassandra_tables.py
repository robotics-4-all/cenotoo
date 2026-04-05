import os

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster
from dotenv import load_dotenv

load_dotenv()

CASSANDRA_SEEDS_ENV = os.getenv("CASSANDRA_SEEDS", "")
if not CASSANDRA_SEEDS_ENV:
    raise RuntimeError("CASSANDRA_SEEDS environment variable is required")
CASSANDRA_NODES = CASSANDRA_SEEDS_ENV.split(",")
CASSANDRA_USERNAME = os.getenv("CASSANDRA_USERNAME", "")
CASSANDRA_PASSWORD = os.getenv("CASSANDRA_PASSWORD", "")

auth_provider = None
if CASSANDRA_USERNAME and CASSANDRA_PASSWORD:
    auth_provider = PlainTextAuthProvider(username=CASSANDRA_USERNAME, password=CASSANDRA_PASSWORD)

cluster = Cluster(CASSANDRA_NODES, auth_provider=auth_provider)
session = cluster.connect()

print(
    "Cassandra connected. Metadata (orgs, projects, collections, users, API keys) "
    "is now stored in PostgreSQL — see postgres/init.sql. "
    "This script only initialises Cassandra for IoT time-series data keyspaces."
)

session.shutdown()
cluster.shutdown()
