from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
import time
from typing import Any

from fastapi.testclient import TestClient
import pytest

from tests.conftest import NOW_MS, rec, rid

Push = Callable[..., list[dict[str, Any]]]
Pull = Callable[..., dict[str, Any]]


def test_empty_database(pull: Pull) -> None:
    body = pull()
    assert body["records"] == []
    assert body["cursor"] == 0
    assert body["more"] is False
    assert len(body["epoch"]) == 32


def test_paging_with_cursor(push: Push, pull: Pull) -> None:
    push(*[rec(n) for n in range(1, 6)])
    seen: list[str] = []
    cursor, pages = 0, []
    while True:
        page = pull(since=cursor, limit=2)
        pages.append((len(page["records"]), page["more"]))
        seen += [r["id"] for r in page["records"]]
        cursor = page["cursor"]
        if not page["more"]:
            break
    assert pages == [(2, True), (2, True), (1, False)]
    assert seen == [rid(n) for n in range(1, 6)]
    assert cursor == 5
    # Nothing new: the cursor stays where it is.
    page = pull(since=cursor)
    assert (page["records"], page["cursor"], page["more"]) == ([], 5, False)


def test_exact_page_has_no_more(push: Push, pull: Pull) -> None:
    push(rec(1), rec(2))
    page = pull(limit=2)
    assert len(page["records"]) == 2
    assert page["more"] is False


def test_updated_record_moves_behind_the_cursor(push: Push, pull: Pull) -> None:
    push(rec(1), rec(2), rec(3))
    cursor = pull()["cursor"]
    push(rec(1, NOW_MS + 1))
    page = pull(since=cursor)
    assert [(r["id"], r["seq"]) for r in page["records"]] == [(rid(1), 4)]
    # The full history holds each record once, at its latest seq.
    assert [r["seq"] for r in pull()["records"]] == [2, 3, 4]


def test_default_limit_is_200(push: Push, pull: Pull) -> None:
    for start in range(0, 250, 50):
        push(*[rec(n) for n in range(start, start + 50)])
    page = pull()
    assert len(page["records"]) == 200
    assert page["more"] is True
    assert page["cursor"] == 200


@pytest.mark.parametrize(
    "params",
    [{"since": -1}, {"limit": 0}, {"limit": 1001}, {"since": "x"}, {"wait": -1}, {"wait": 61}],
)
def test_invalid_parameters(client: TestClient, params: dict[str, Any]) -> None:
    assert client.get("/v1/changes", params=params).status_code == 422


def wait_for_changes(client: TestClient, since: int, wait: int) -> tuple[dict[str, Any], float]:
    """A waiting `/v1/changes`, and how long it took."""
    start = time.monotonic()
    response = client.get("/v1/changes", params={"since": since, "wait": wait})
    assert response.status_code == 200, response.text
    return response.json(), time.monotonic() - start


def test_waiting_answers_at_once_when_there_are_newer_records(
    client: TestClient, push: Push
) -> None:
    push(rec(1))
    page, elapsed = wait_for_changes(client, since=0, wait=30)
    assert [r["id"] for r in page["records"]] == [rid(1)]
    assert elapsed < 5


def test_a_push_wakes_a_waiting_request(client: TestClient, push: Push) -> None:
    push(rec(1))
    with ThreadPoolExecutor(1) as pool:
        waiting = pool.submit(wait_for_changes, client, 1, 30)
        time.sleep(0.3)
        assert not waiting.done()
        push(rec(2), device="mac-b")
        page, elapsed = waiting.result(timeout=10)
    assert [r["id"] for r in page["records"]] == [rid(2)]
    assert elapsed < 10


def test_waiting_ends_empty_after_the_wait(client: TestClient, push: Push) -> None:
    push(rec(1))
    page, elapsed = wait_for_changes(client, since=1, wait=1)
    assert (page["records"], page["cursor"], page["more"]) == ([], 1, False)
    assert elapsed >= 0.9


def test_a_stale_push_wakes_no_one(client: TestClient, push: Push) -> None:
    push(rec(1, NOW_MS + 1))
    with ThreadPoolExecutor(1) as pool:
        waiting = pool.submit(wait_for_changes, client, 1, 2)
        time.sleep(0.3)
        assert push(rec(1))[0]["status"] == "stale"
        page, elapsed = waiting.result(timeout=10)
    assert page["records"] == []
    assert elapsed >= 1.9


def test_waiting_with_a_cursor_ahead_answers_at_once_with_a_new_epoch(client: TestClient) -> None:
    epoch = client.get("/v1/health").json()["epoch"]
    page, elapsed = wait_for_changes(client, since=5, wait=30)
    assert (page["cursor"], elapsed < 5) == (0, True)
    assert page["epoch"] != epoch


def test_health_says_how_long_changes_can_wait(client: TestClient) -> None:
    assert client.get("/v1/health").json()["maxWait"] == 60
