import base64
import importlib.util
import os

_SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "scripts", "generate-cluster-id.py")
_spec = importlib.util.spec_from_file_location("generate_cluster_id", _SCRIPT_PATH)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
generate_kafka_cluster_id = _mod.generate_kafka_cluster_id


class TestGenerateKafkaClusterId:
    def test_returns_string(self):
        result = generate_kafka_cluster_id()
        assert isinstance(result, str)

    def test_is_base64_decodable(self):
        result = generate_kafka_cluster_id()
        padded = result + "=" * (4 - len(result) % 4)
        decoded = base64.urlsafe_b64decode(padded)
        assert len(decoded) == 16

    def test_unique_on_each_call(self):
        id1 = generate_kafka_cluster_id()
        id2 = generate_kafka_cluster_id()
        assert id1 != id2

    def test_no_padding_characters(self):
        result = generate_kafka_cluster_id()
        assert "=" not in result
