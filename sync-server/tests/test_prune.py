from collections.abc import Callable
import time
from typing import Any

from fastapi.testclient import TestClient

from app.prune import DAY_MS, prune
from app.store import Store
from tests.conftest import bid, rec, rid

Push = Callable[..., list[dict[str, Any]]]
Pull = Callable[..., dict[str, Any]]


def now_ms() -> int:
    return int(time.time() * 1000)


def ids(pull: Pull) -> list[tuple[str, str]]:
    return [(r["collection"], r["id"]) for r in pull()["records"]]


def test_prunes_old_unpinned_clips_and_old_tombstones(store: Store, push: Push, pull: Pull) -> None:
    now = now_ms()
    push(
        rec(1, now - 61 * DAY_MS),  # old clip: pruned
        rec(2, now - 59 * DAY_MS),  # recent clip: kept
        rec(3, now - 400 * DAY_MS, keep=True),  # pinned clip: kept
        rec(4, now - 400 * DAY_MS, collection="snippet"),  # snippets aren't pruned
        rec(5, now - 400 * DAY_MS, collection="action"),
        rec(6, now - 400 * DAY_MS, collection="meta"),  # the key check stays
        rec(7, now - 181 * DAY_MS, deleted=True),  # old tombstone: pruned
        rec(8, now - 179 * DAY_MS, deleted=True),  # recent tombstone: kept
        rec(9, now - 181 * DAY_MS, collection="snippet", deleted=True),  # pruned
        rec(10, now - 100 * DAY_MS, collection="snippet", deleted=True),  # kept
    )
    assert prune(store, clip_days=60, now_ms=now) == (3, 0)
    assert ids(pull) == [
        ("clip", rid(2)),
        ("clip", rid(3)),
        ("snippet", rid(4)),
        ("action", rid(5)),
        ("meta", rid(6)),
        ("clip", rid(8)),
        ("snippet", rid(10)),
    ]


def test_prune_clip_days_is_configurable(store: Store, push: Push, pull: Pull) -> None:
    now = now_ms()
    push(rec(1, now - 11 * DAY_MS), rec(2, now - 9 * DAY_MS))
    prune(store, clip_days=10, now_ms=now)
    assert ids(pull) == [("clip", rid(2))]


def test_seq_stays_monotonic_after_pruning_the_highest_record(
    store: Store, push: Push, pull: Pull
) -> None:
    now = now_ms()
    push(rec(1, now), rec(2, now - 100 * DAY_MS))
    cursor = pull()["cursor"]
    assert cursor == 2
    prune(store, clip_days=60, now_ms=now)
    assert ids(pull) == [("clip", rid(1))]
    # The next record gets 3, not 2: a client whose cursor is at 2 still sees it.
    assert push(rec(3, now))[0]["seq"] == 3
    assert [r["id"] for r in pull(since=cursor)["records"]] == [rid(3)]


def test_seq_stays_monotonic_across_restarts(client: TestClient, store: Store, push: Push) -> None:
    now = now_ms()
    push(rec(1, now), rec(2, now - 100 * DAY_MS))
    prune(store, clip_days=60, now_ms=now)
    path = store._db.execute("PRAGMA database_list").fetchone()["file"]
    reopened = Store(path)
    try:
        assert reopened.last_seq() == 2
    finally:
        reopened.close()


def test_blob_gc(client: TestClient, store: Store, push: Push) -> None:
    for n in range(1, 5):
        client.put(f"/v1/blobs/{bid(n)}", content=b"sealed")
    now = now_ms()
    push(
        rec(1, now, blobs=[bid(1)]),  # referenced by a live record
        rec(2, now - 400 * DAY_MS, keep=True, blobs=[bid(2)]),  # referenced by a pinned clip
        rec(3, now - 100 * DAY_MS, blobs=[bid(3)]),  # its record gets pruned
    )
    # bid(4) is referenced by nothing.

    # Within the first day every blob stays: its record may still be on its way.
    assert prune(store, clip_days=60, now_ms=now) == (1, 0)
    assert all(store.get_blob(bid(n)) is not None for n in range(1, 5))

    later = now + 2 * DAY_MS
    assert prune(store, clip_days=60, now_ms=later) == (0, 2)
    assert store.get_blob(bid(1)) is not None
    assert store.get_blob(bid(2)) is not None
    assert store.get_blob(bid(3)) is None
    assert store.get_blob(bid(4)) is None


def test_blob_referenced_by_a_tombstoned_record_is_collected(
    client: TestClient, store: Store, push: Push
) -> None:
    client.put(f"/v1/blobs/{bid(1)}", content=b"sealed")
    now = now_ms()
    push(rec(1, now, blobs=[bid(1)]))
    push(rec(1, now + 1, deleted=True))
    prune(store, clip_days=60, now_ms=now + 2 * DAY_MS)
    assert store.get_blob(bid(1)) is None


def test_startup_prunes(tmp_path: Any) -> None:
    from tests.conftest import AUTH, make_app

    now = now_ms()
    with TestClient(make_app(tmp_path), headers=AUTH) as client:
        client.post("/v1/push", json={"device": "mac-a", "records": [rec(1, now - 100 * DAY_MS)]})
        assert len(client.get("/v1/changes").json()["records"]) == 1
    with TestClient(make_app(tmp_path), headers=AUTH) as client:
        assert client.get("/v1/changes").json()["records"] == []
