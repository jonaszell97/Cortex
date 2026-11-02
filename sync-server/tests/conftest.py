from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

from app.config import Settings
from app.main import create_app
from app.store import Store

TOKEN = "test-token-0123456789abcdef"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
# 2026-10-19, a fixed "now" for records. Pruning at startup runs on an empty database.
NOW_MS = 1_792_483_200_123


def make_app(data_dir: Path, **overrides: Any) -> FastAPI:
    return create_app(Settings(token=TOKEN, data_dir=data_dir, **overrides))


@pytest.fixture
def client(tmp_path: Path) -> Iterator[TestClient]:
    with TestClient(make_app(tmp_path), headers=AUTH) as client:
        yield client


@pytest.fixture
def anon(client: TestClient) -> TestClient:
    """The same app, without the token."""
    client.headers.pop("Authorization")
    return client


@pytest.fixture
def store(client: TestClient) -> Store:
    return client.app.state.store  # type: ignore[attr-defined]


def rid(n: int) -> str:
    return f"{n:032x}"


def bid(n: int) -> str:
    return f"b{n:031x}"


def rec(n: int, modified_at: int = NOW_MS, **fields: Any) -> dict[str, Any]:
    """A record as a client pushes it. The payload is any base64; the server can't read it."""
    record = {
        "collection": "clip",
        "id": rid(n),
        "modifiedAt": modified_at,
        "device": "mac-a",
        "deleted": False,
        "keep": False,
        "blobs": [],
        "payload": "c2VhbGVk",
    }
    record.update(fields)
    if record["deleted"] and "payload" not in fields:
        record["payload"] = None
    return record


@pytest.fixture
def push(client: TestClient) -> Callable[..., list[dict[str, Any]]]:
    def push(*records: dict[str, Any], device: str = "mac-a") -> list[dict[str, Any]]:
        response = client.post("/v1/push", json={"device": device, "records": list(records)})
        assert response.status_code == 200, response.text
        return response.json()["results"]

    return push


@pytest.fixture
def pull(client: TestClient) -> Callable[..., dict[str, Any]]:
    def pull(since: int = 0, limit: int = 200) -> dict[str, Any]:
        response = client.get("/v1/changes", params={"since": since, "limit": limit})
        assert response.status_code == 200, response.text
        return response.json()

    return pull
