import base64
from collections.abc import Iterator
from pathlib import Path

from fastapi.testclient import TestClient
import pytest

from tests.conftest import AUTH, bid, make_app, rec, rid


@pytest.fixture
def small(tmp_path: Path) -> Iterator[TestClient]:
    app = make_app(tmp_path, max_blob_bytes=1024, max_json_bytes=4096)
    with TestClient(app, headers=AUTH) as client:
        yield client


def chunks(total: int, size: int = 256) -> Iterator[bytes]:
    for start in range(0, total, size):
        yield b"x" * min(size, total - start)


def test_blob_at_the_limit_is_stored(small: TestClient) -> None:
    assert small.put(f"/v1/blobs/{bid(1)}", content=b"x" * 1024).status_code == 200


def test_blob_over_the_limit_is_refused(small: TestClient) -> None:
    assert small.put(f"/v1/blobs/{bid(1)}", content=b"x" * 1025).status_code == 413
    assert small.get(f"/v1/blobs/{bid(1)}").status_code == 404


def test_chunked_blob_over_the_limit_is_refused(small: TestClient) -> None:
    # No Content-Length: the limit is enforced while reading.
    response = small.put(f"/v1/blobs/{bid(1)}", content=chunks(2048))
    assert response.status_code == 413
    assert small.get(f"/v1/blobs/{bid(1)}").status_code == 404


def test_chunked_blob_under_the_limit_is_stored(small: TestClient) -> None:
    assert small.put(f"/v1/blobs/{bid(1)}", content=chunks(1000)).status_code == 200
    assert small.get(f"/v1/blobs/{bid(1)}").content == b"x" * 1000


def test_push_over_the_limit_is_refused(small: TestClient) -> None:
    record = rec(1, payload="eHh4" * 1500)
    response = small.post("/v1/push", json={"device": "mac-a", "records": [record]})
    assert response.status_code == 413
    assert small.get("/v1/changes").json()["records"] == []


def test_chunked_push_over_the_limit_is_refused(small: TestClient) -> None:
    response = small.post(
        "/v1/push", content=chunks(8192), headers={"Content-Type": "application/json"}
    )
    assert response.status_code == 413


def test_missing_over_the_limit_is_refused(small: TestClient) -> None:
    response = small.post("/v1/blobs/missing", json={"ids": [bid(n) for n in range(200)]})
    assert response.status_code == 413


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.config import MB, Settings

    monkeypatch.setenv("SYNC_TOKEN", "t" * 16)
    monkeypatch.setenv("DATA_DIR", "/tmp/sync")
    monkeypatch.setenv("PRUNE_CLIP_DAYS", "30")
    monkeypatch.setenv("MAX_BLOB_MB", "8")
    settings = Settings.from_env()
    assert settings.data_dir == Path("/tmp/sync")
    assert settings.prune_clip_days == 30
    assert settings.max_blob_bytes == 8 * MB
    assert settings.max_json_bytes == 32 * MB


@pytest.mark.parametrize("token", [None, "", "short"])
def test_settings_need_a_token(monkeypatch: pytest.MonkeyPatch, token: str | None) -> None:
    from app.config import Settings

    if token is None:
        monkeypatch.delenv("SYNC_TOKEN", raising=False)
    else:
        monkeypatch.setenv("SYNC_TOKEN", token)
    with pytest.raises(RuntimeError, match="SYNC_TOKEN"):
        Settings.from_env()


def big_payload(size: int) -> str:
    return base64.b64encode(b"x" * size).decode()


def test_record_payload_over_the_limit_is_refused(tmp_path: Path) -> None:
    app = make_app(tmp_path, max_record_bytes=1000)
    with TestClient(app, headers=AUTH) as client:
        ok = client.post(
            "/v1/push", json={"device": "mac-a", "records": [rec(1, payload=big_payload(1000))]}
        )
        assert ok.status_code == 200
        response = client.post(
            "/v1/push", json={"device": "mac-a", "records": [rec(2, payload=big_payload(1001))]}
        )
        assert response.status_code == 413
        assert [record["id"] for record in client.get("/v1/changes").json()["records"]] == [rid(1)]


def test_a_page_stops_at_its_byte_limit(tmp_path: Path) -> None:
    app = make_app(tmp_path, max_page_bytes=2500)
    with TestClient(app, headers=AUTH) as client:
        records = [rec(n, payload=big_payload(1000)) for n in range(1, 6)]
        assert (
            client.post("/v1/push", json={"device": "mac-a", "records": records}).status_code == 200
        )

        seen: list[str] = []
        since = 0
        pages = 0
        while True:
            page = client.get("/v1/changes", params={"since": since, "limit": 1000}).json()
            pages += 1
            assert len(page["records"]) <= 3
            seen += [record["id"] for record in page["records"]]
            since = page["cursor"]
            if not page["more"]:
                break
        assert seen == [rid(n) for n in range(1, 6)]
        assert pages == 2


def test_a_record_larger_than_a_page_still_comes_alone(tmp_path: Path) -> None:
    app = make_app(tmp_path, max_page_bytes=100)
    with TestClient(app, headers=AUTH) as client:
        records = [rec(1, payload=big_payload(1000)), rec(2)]
        client.post("/v1/push", json={"device": "mac-a", "records": records})
        page = client.get("/v1/changes").json()
        assert [record["id"] for record in page["records"]] == [rid(1)]
        assert page["more"] is True


def test_a_full_server_refuses_new_data_but_takes_deletions(tmp_path: Path) -> None:
    app = make_app(tmp_path, max_storage_bytes=1)
    with TestClient(app, headers=AUTH) as client:
        push = client.post("/v1/push", json={"device": "mac-a", "records": [rec(1)]})
        assert push.status_code == 507
        assert client.put(f"/v1/blobs/{bid(1)}", content=b"x").status_code == 507
        tombstone = rec(1, deleted=True)
        assert (
            client.post("/v1/push", json={"device": "mac-a", "records": [tombstone]}).status_code
            == 200
        )


def test_storage_cap_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.config import MB, Settings

    monkeypatch.setenv("SYNC_TOKEN", "t" * 16)
    monkeypatch.setenv("MAX_STORAGE_MB", "100")
    assert Settings.from_env().max_storage_bytes == 100 * MB
