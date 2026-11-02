"""Replays the protocol fixtures (tests/fixtures/*.json) against the server."""

import base64
import json
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient
import pytest

from tests.conftest import TOKEN

FIXTURES = sorted((Path(__file__).parent / "fixtures").glob("*.json"))


def resolve(expected: Any, actual: Any, bound: dict[str, Any]) -> Any:
    """`expected` with its placeholders replaced by the matching parts of `actual`."""
    if expected == "<epoch>":
        return bound.setdefault("epoch", actual)
    if expected == "<any>":
        return actual
    if isinstance(expected, dict) and isinstance(actual, dict):
        return {key: resolve(value, actual.get(key), bound) for key, value in expected.items()}
    if isinstance(expected, list) and isinstance(actual, list) and len(expected) == len(actual):
        return [resolve(e, a, bound) for e, a in zip(expected, actual, strict=True)]
    return expected


def test_fixtures_exist() -> None:
    assert len(FIXTURES) >= 4


@pytest.mark.parametrize("path", FIXTURES, ids=lambda path: path.stem)
def test_fixture(anon: TestClient, path: Path) -> None:
    scenario = json.loads(path.read_text())
    bound: dict[str, Any] = {}
    for index, step in enumerate(scenario["steps"]):
        request, expected = step["request"], step["response"]
        headers = {"Authorization": f"Bearer {TOKEN}"} if request.get("auth", True) else {}
        kwargs: dict[str, Any] = {}
        if "json" in request:
            kwargs["json"] = request["json"]
        if "bodyBase64" in request:
            kwargs["content"] = base64.b64decode(request["bodyBase64"])
        response = anon.request(request["method"], request["path"], headers=headers, **kwargs)

        where = f"{path.name} step {index}"
        assert response.status_code == expected["status"], f"{where}: {response.text}"
        if "json" in expected:
            actual = response.json()
            assert resolve(expected["json"], actual, bound) == actual, where
        if "bodyBase64" in expected:
            assert response.content == base64.b64decode(expected["bodyBase64"]), where
        assert response.headers["X-Sync-Epoch"] == bound.setdefault(
            "epoch", response.headers["X-Sync-Epoch"]
        ), where
