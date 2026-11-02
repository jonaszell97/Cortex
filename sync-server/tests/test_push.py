import base64
from collections.abc import Callable
import time
from typing import Any

from fastapi.testclient import TestClient
import pytest

from tests.conftest import NOW_MS, bid, rec, rid

Push = Callable[..., list[dict[str, Any]]]
Pull = Callable[..., dict[str, Any]]


def test_new_record_is_applied_with_increasing_seq(push: Push, pull: Pull) -> None:
    results = push(rec(1), rec(2))
    assert results == [
        {"collection": "clip", "id": rid(1), "status": "applied", "seq": 1},
        {"collection": "clip", "id": rid(2), "status": "applied", "seq": 2},
    ]
    records = pull()["records"]
    assert [r["id"] for r in records] == [rid(1), rid(2)]
    assert records[0] == {**rec(1), "seq": 1}


def test_newer_write_wins(push: Push, pull: Pull) -> None:
    push(rec(1, NOW_MS, payload="b2xk"))
    results = push(rec(1, NOW_MS + 1, device="mac-b", payload="bmV3"), device="mac-b")
    assert results[0]["status"] == "applied"
    assert results[0]["seq"] == 2
    records = pull()["records"]
    assert len(records) == 1
    assert records[0]["payload"] == "bmV3"
    assert records[0]["device"] == "mac-b"
    assert records[0]["seq"] == 2


def test_older_write_is_stale_and_changes_nothing(push: Push, pull: Pull) -> None:
    push(rec(1, NOW_MS, payload="bmV3"))
    results = push(rec(1, NOW_MS - 1, device="mac-b", payload="b2xk"), device="mac-b")
    assert results == [{"collection": "clip", "id": rid(1), "status": "stale", "seq": 1}]
    records = pull()["records"]
    assert records == [{**rec(1, NOW_MS, payload="bmV3"), "seq": 1}]
    # A stale answer uses up no seq.
    assert push(rec(2))[0]["seq"] == 2


def test_identical_repeat_is_idempotent(push: Push, pull: Pull) -> None:
    record = rec(1, blobs=[bid(1)], keep=True)
    assert push(record)[0] == {"collection": "clip", "id": rid(1), "status": "applied", "seq": 1}
    # A push that died halfway is sent again: the same answer, nothing new to pull.
    assert push(record)[0] == {"collection": "clip", "id": rid(1), "status": "applied", "seq": 1}
    assert pull(since=1)["records"] == []
    assert push(rec(2))[0]["seq"] == 2


def test_equal_timestamp_is_broken_by_device(push: Push, pull: Pull) -> None:
    push(rec(1, NOW_MS, device="mac-b", payload="Ymk="))
    stale = push(rec(1, NOW_MS, device="mac-a", payload="YQ=="))
    assert stale[0]["status"] == "stale"
    applied = push(rec(1, NOW_MS, device="mac-c", payload="Yw=="))
    assert applied[0]["status"] == "applied"
    assert pull()["records"][0]["device"] == "mac-c"


def test_same_key_with_other_content_replaces(push: Push, pull: Pull) -> None:
    push(rec(1, NOW_MS, payload="b25l"))
    results = push(rec(1, NOW_MS, payload="dHdv"))
    assert results[0] == {"collection": "clip", "id": rid(1), "status": "applied", "seq": 2}
    assert pull()["records"][0]["payload"] == "dHdv"


def test_tombstone_replaces_record(push: Push, pull: Pull) -> None:
    push(rec(1, NOW_MS, blobs=[bid(1)]))
    push(rec(1, NOW_MS + 1, deleted=True))
    records = pull()["records"]
    assert records == [{**rec(1, NOW_MS + 1, deleted=True), "seq": 2}]
    assert records[0]["payload"] is None
    assert records[0]["blobs"] == []


def test_sealed_tombstone_keeps_its_payload(push: Push, pull: Pull) -> None:
    # Protocol v2: a tombstone carries a small sealed payload, so a client can authenticate it.
    push(rec(1, NOW_MS))
    push(rec(1, NOW_MS + 1, deleted=True, payload="dG9tYg=="))
    records = pull()["records"]
    assert records == [{**rec(1, NOW_MS + 1, deleted=True, payload="dG9tYg=="), "seq": 2}]


def test_modified_at_up_to_a_day_ahead_is_accepted(push: Push) -> None:
    soon = int(time.time() * 1000) + 23 * 60 * 60 * 1000
    assert push(rec(1, soon))[0]["status"] == "applied"


def test_collections_are_separate(push: Push, pull: Pull) -> None:
    push(
        rec(1, collection="clip"),
        rec(1, collection="snippet"),
        rec(1, collection="action"),
        rec(1, collection="reading"),
        rec(1, collection="knowledge"),
        rec(1, collection="device"),
    )
    push(rec(1, collection="meta"))
    assert [r["collection"] for r in pull()["records"]] == [
        "clip",
        "snippet",
        "action",
        "reading",
        "knowledge",
        "device",
        "meta",
    ]


def test_records_in_one_push_apply_in_order(push: Push, pull: Pull) -> None:
    results = push(rec(1, NOW_MS, payload="YQ=="), rec(1, NOW_MS + 1, payload="Yg=="))
    assert [r["status"] for r in results] == ["applied", "applied"]
    assert [r["seq"] for r in results] == [1, 2]
    assert pull()["records"][0]["payload"] == "Yg=="


def test_failed_push_applies_nothing(client: TestClient, pull: Pull) -> None:
    response = client.post(
        "/v1/push", json={"device": "mac-a", "records": [rec(1), rec(2, id="nope")]}
    )
    assert response.status_code == 422
    assert pull()["records"] == []


@pytest.mark.parametrize(
    "fields",
    [
        {"id": "3F9C" + "0" * 28},  # upper case
        {"id": "0" * 31},
        {"id": "0" * 33},
        {"collection": "settings"},
        {"modifiedAt": -1},
        {"modifiedAt": "soon"},
        {"device": ""},
        {"device": "mac a"},
        {"device": "x" * 65},
        {"payload": None},  # live record without payload
        {"deleted": True, "payload": base64.b64encode(bytes(1025)).decode()},  # large tombstone
        {"modifiedAt": int(time.time() * 1000) + 24 * 60 * 60 * 1000 + 60_000},  # a day ahead
        {"payload": "not base64!"},
        {"blobs": ["xyz"]},
        {"blobs": [bid(1)] * 1001},
    ],
)
def test_invalid_records_are_rejected(client: TestClient, fields: dict[str, Any]) -> None:
    response = client.post("/v1/push", json={"device": "mac-a", "records": [rec(1, **fields)]})
    assert response.status_code == 422, response.text
    # The error never echoes the input (it could be a payload).
    assert "c2VhbGVk" not in response.text


def test_missing_fields_are_rejected(client: TestClient) -> None:
    record = rec(1)
    del record["modifiedAt"]
    response = client.post("/v1/push", json={"device": "mac-a", "records": [record]})
    assert response.status_code == 422


def test_push_has_a_record_limit(client: TestClient) -> None:
    records = [rec(n) for n in range(501)]
    response = client.post("/v1/push", json={"device": "mac-a", "records": records})
    assert response.status_code == 422


def test_push_rejects_malformed_json(client: TestClient) -> None:
    response = client.post("/v1/push", content=b"{", headers={"Content-Type": "application/json"})
    assert response.status_code == 422
