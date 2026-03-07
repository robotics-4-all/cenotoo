import base64
import uuid


def generate_kafka_cluster_id():
    # Generate a random UUID (128-bit)
    raw_uuid = uuid.uuid4()

    # Convert the UUID to a 16-byte binary string
    uuid_bytes = raw_uuid.bytes

    # Encode the binary UUID as a Base64 string
    cluster_id = base64.urlsafe_b64encode(uuid_bytes).decode("utf-8").rstrip("=")

    print(f"Generated Kafka Cluster ID: {cluster_id}")
    return cluster_id


if __name__ == "__main__":
    generate_kafka_cluster_id()
