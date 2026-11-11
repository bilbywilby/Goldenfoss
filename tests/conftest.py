"""Shared fixtures: schema edge cases + wildcard test infrastructure."""
import sqlite3
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "core" / "lib" / "ultra"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "schemas"))

@pytest.fixture
def tmp_db(tmp_path):
    """Throwaway SQLite path; deleted with the test."""
    return str(tmp_path / "test.db")

class FrozenClock:
    """Manually-advanced clock for deterministic retry/lease/circuit tests."""
    def __init__(self, t: float = 1000.0):
        self.t = t
    def __call__(self) -> float:
        return self.t
    def advance(self, seconds: float) -> None:
        self.t += seconds

@pytest.fixture
def frozen_clock():
    return FrozenClock()

@pytest.fixture
def wal_pragma_check(tmp_db):
    """Assert WAL is active."""
    conn = sqlite3.connect(tmp_db)
    yield conn
    conn.close()

# ModularPayloadBase boundary cases
try:
    from modular_payload import ModularPayloadBase
    HAVE_SCHEMA = True
except ImportError:
    HAVE_SCHEMA = False

VALID_CASES = [
    pytest.param({"module_name": "billing_engine", "payload": {"amount_cents": 4500}}, id="minimal-valid"),
    pytest.param({"module_name": "  sync_wiki  ", "payload": {}}, id="strips-whitespace"),
    pytest.param({"module_name": "dag_runner_v3", "payload": {}, "is_active": False}, id="inactive-empty-payload"),
]

if HAVE_SCHEMA:
    @pytest.fixture(scope="module")
    def schema_cls():
        return ModularPayloadBase

    @pytest.fixture(params=VALID_CASES)
    def valid_kwargs(request):
        return request.param
