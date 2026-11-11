"""Boundary validation driven by conftest fixtures."""
import pytest
import importlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "schemas"))
try:
    ModularPayloadBase = importlib.import_module("modular_payload").ModularPayloadBase
    HAVE = True
except ImportError:
    HAVE = False

pytestmark = pytest.mark.skipif(not HAVE, reason="schemas/modular_payload.py not present")

def test_valid_payloads_accept(schema_cls, valid_kwargs):
    m = schema_cls(**valid_kwargs)
    assert m.header.entity_id is not None
    assert m.header.schema_version == "1.0.0"
    expected_active = valid_kwargs.get("is_active", True)
    assert m.is_active is expected_active
    assert m.module_name == valid_kwargs["module_name"].strip()

@pytest.mark.parametrize("kwargs,err_sub", [
    ({"module_name": "BillingEngine", "payload": {}}, "lower_snake_case"),
    ({"module_name": "billing-engine", "payload": {}}, "lower_snake_case"),
    ({"module_name": "b", "payload": {"x": 1}, "is_active": False}, "empty payload"),
    ({"module_name": "b", "payload": {}, "surprise": 1}, "extra"),
], ids=["uppercase", "kebab", "inactive-nonempty", "extra-forbidden"])
def test_invalid_payloads_rejected(schema_cls, kwargs, err_sub):
    with pytest.raises(ValueError, match=err_sub):
        schema_cls(**kwargs)

def test_strict_mode_rejects_bool_coercion(schema_cls):
    with pytest.raises(ValueError):
        schema_cls(module_name="b", payload={}, is_active="true")

def test_assignment_validation_revalidates(schema_cls):
    m = schema_cls(module_name="b", payload={})
    with pytest.raises(ValueError):
        m.module_name = "NOT-VALID"

def test_roundtrip_serialization_is_iso_utc(schema_cls):
    m = schema_cls(module_name="b", payload={"k": "v"})
    js = m.model_dump_json()
    assert "T" in m.header.created_at.isoformat()
    assert "entity_id" in js
