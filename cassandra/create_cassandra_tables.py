import os
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Environment Variables
CASSANDRA_SEEDS_ENV = os.getenv("CASSANDRA_SEEDS", "")
if not CASSANDRA_SEEDS_ENV:
    raise RuntimeError("CASSANDRA_SEEDS environment variable is required")
CASSANDRA_NODES = CASSANDRA_SEEDS_ENV.split(",")  # Comma-separated list of IPs


# Establish connection to the Cassandra cluster
cluster = Cluster(CASSANDRA_NODES)
session = cluster.connect()

# Creating the metadata keyspace
session.execute("""
    CREATE KEYSPACE IF NOT EXISTS metadata 
    WITH REPLICATION = { 
        'class' : 'SimpleStrategy', 
        'replication_factor' : 2
    };
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

# Closing the session and cluster connection
session.shutdown()
cluster.shutdown()

print("Metadata keyspace and tables created successfully.")
