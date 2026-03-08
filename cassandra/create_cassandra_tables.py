import os

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Environment Variables
CASSANDRA_SEEDS_ENV = os.getenv("CASSANDRA_SEEDS", "")
if not CASSANDRA_SEEDS_ENV:
    raise RuntimeError("CASSANDRA_SEEDS environment variable is required")
CASSANDRA_NODES = CASSANDRA_SEEDS_ENV.split(",")  # Comma-separated list of IPs
CASSANDRA_DC = os.getenv("CASSANDRA_DC", "datacenter1")
CASSANDRA_RF = int(os.getenv("CASSANDRA_RF", "2"))
CASSANDRA_USERNAME = os.getenv("CASSANDRA_USERNAME", "")
CASSANDRA_PASSWORD = os.getenv("CASSANDRA_PASSWORD", "")

# Establish connection to the Cassandra cluster
auth_provider = None
if CASSANDRA_USERNAME and CASSANDRA_PASSWORD:
    auth_provider = PlainTextAuthProvider(username=CASSANDRA_USERNAME, password=CASSANDRA_PASSWORD)

cluster = Cluster(CASSANDRA_NODES, auth_provider=auth_provider)
session = cluster.connect()

# Creating the metadata keyspace with NetworkTopologyStrategy
# NTS is recommended even for single-DC deployments for future multi-DC expansion
session.execute(f"""
    CREATE KEYSPACE IF NOT EXISTS metadata
    WITH REPLICATION = {{
        'class' : 'NetworkTopologyStrategy',
        '{CASSANDRA_DC}' : {CASSANDRA_RF}
    }};
""")

# Switching to the metadata keyspace
session.set_keyspace("metadata")

# Creating the User table
session.execute("""
    CREATE TABLE IF NOT EXISTS user (
        id UUID PRIMARY KEY,
        username TEXT,
        password TEXT,
        organization_id UUID
    );
""")

# Creating the Organization table
session.execute("""
    CREATE TABLE IF NOT EXISTS organization (
        id UUID PRIMARY KEY,
        organization_name TEXT,
        description TEXT,
        creation_date TIMESTAMP,
        tags LIST<TEXT>
    );
""")

# Creating the Project table
session.execute("""
    CREATE TABLE IF NOT EXISTS project (
        id UUID PRIMARY KEY,
        organization_id UUID,
        project_name TEXT,
        description TEXT,
        creation_date TIMESTAMP,
        tags LIST<TEXT>
    );
""")

# Creating the Collection table
session.execute("""
    CREATE TABLE IF NOT EXISTS collection (
        id UUID PRIMARY KEY,
        organization_id UUID,
        project_id UUID,
        collection_name TEXT,
        description TEXT,
        creation_date TIMESTAMP,
        tags LIST<TEXT>
    );
""")

# Creating the API Keys table
session.execute("""
    CREATE TABLE IF NOT EXISTS api_keys (
        id UUID PRIMARY KEY,
        project_id UUID,
        key_type TEXT,
        api_key TEXT,
        created_at TIMESTAMP
    );
""")

session.execute("""
    CREATE TABLE IF NOT EXISTS revoked_tokens (
        jti TEXT PRIMARY KEY,
        revoked_at TIMESTAMP,
        expires_at TIMESTAMP
    );
""")

session.shutdown()
cluster.shutdown()

print("Metadata keyspace and tables created successfully.")
