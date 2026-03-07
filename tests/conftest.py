from unittest.mock import MagicMock

import pytest


@pytest.fixture
def mock_kafka_message():
    msg = MagicMock()
    msg.error.return_value = None
    msg.value.return_value = b'{"temperature": 22.5, "humidity": 60}'
    msg.key.return_value = b"sensor_001"
    msg.offset.return_value = 1
    msg.partition.return_value = 0
    msg.topic.return_value = "test_org.test_project.test_collection"
    return msg


@pytest.fixture
def mock_cassandra_session():
    session = MagicMock()
    session.prepare.return_value = MagicMock()
    session.execute.return_value = None
    session.shutdown.return_value = None
    return session


@pytest.fixture
def mock_cassandra_cluster(mock_cassandra_session):
    cluster = MagicMock()
    cluster.connect.return_value = mock_cassandra_session
    cluster.shutdown.return_value = None
    return cluster
