from collections.abc import Callable
from pathlib import Path
import subprocess
import sys
from typing import Any

from fastapi.testclient import TestClient

from app.store import Store
from tests.conftest import AUTH, bid, make_app, rec

Push = Callable[..., list[dict[str, Any]]]
Pull = Callable[..., dict[str, Any]]

SERVER_DIR = Path(__file__).parent.parent


def epoch_of(data_dir: Path) -> str:
    with TestClient(make_app(data_dir)) as client:
        return client.get("/v1/health").json()["epoch"]


def test_fresh_database_gets_a_new_epoch(tmp_path: Path) -> None:
    first = epoch_of(tmp_path / "one")
    second = epoch_of(tmp_path / "two")
    assert len(first) == len(second) == 32
    assert first != second


def test_epoch_survives_a_restart(tmp_path: Path) -> None:
    assert epoch_of(tmp_path) == epoch_of(tmp_path)


def test_every_response_carries_the_epoch(client: TestClient, anon: TestClient) -> None:
    epoch = client.get("/v1/health").json()["epoch"]
    client.put(f"/v1/blobs/{bid(1)}", content=b"sealed")
    responses = [
        client.get("/v1/health"),
        client.get("/v1/changes"),
        client.post("/v1/push", json={"device": "mac-a", "records": [rec(1)]}),
        client.post("/v1/blobs/missing", json={"ids": [bid(1)]}),
        client.put(f"/v1/blobs/{bid(2)}", content=b"sealed"),
        client.get(f"/v1/blobs/{bid(1)}"),
        client.get(f"/v1/blobs/{bid(9)}"),  # 404
        client.get("/v1/changes", params={"limit": 0}),  # 422
    ]
    for response in responses:
        assert response.headers["X-Sync-Epoch"] == epoch
        if response.status_code == 200 and response.headers["Content-Type"] == "application/json":
            assert response.json()["epoch"] == epoch
    assert anon.get("/v1/changes").headers["X-Sync-Epoch"] == epoch  # 401


def test_cursor_ahead_of_the_database_rotates_the_epoch(
    client: TestClient, push: Push, pull: Pull
) -> None:
    # A database restored from a backup has the old epoch but hands out seq numbers again.
    old = pull()["epoch"]
    push(rec(1), rec(2))
    response = pull(since=5)
    assert response["records"] == []
    assert response["cursor"] == 0
    assert response["epoch"] != old
    assert client.get("/v1/health").json()["epoch"] == response["epoch"]
    # The client starts over from 0 and gets everything.
    assert len(pull()["records"]) == 2
    # A cursor at the last seq is fine.
    assert pull(since=2)["epoch"] == response["epoch"]


def test_rotate_epoch_command(tmp_path: Path) -> None:
    old = epoch_of(tmp_path)
    result = subprocess.run(
        [sys.executable, "-m", "app.store", "rotate-epoch", str(tmp_path / "sync.sqlite")],
        cwd=SERVER_DIR,
        capture_output=True,
        text=True,
        check=True,
    )
    new = epoch_of(tmp_path)
    assert new != old
    assert new in result.stdout


def test_rotate_epoch_command_needs_a_database(tmp_path: Path) -> None:
    result = subprocess.run(
        [sys.executable, "-m", "app.store", "rotate-epoch", str(tmp_path / "nope.sqlite")],
        cwd=SERVER_DIR,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert not (tmp_path / "nope.sqlite").exists()


def test_store_keeps_data_across_reopen(tmp_path: Path) -> None:
    with TestClient(make_app(tmp_path), headers=AUTH) as client:
        client.post("/v1/push", json={"device": "mac-a", "records": [rec(1)]})
    store = Store(tmp_path / "sync.sqlite")
    try:
        assert store.last_seq() == 1
        assert len(store.changes(0, 10)[0]) == 1
    finally:
        store.close()
