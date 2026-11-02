from fastapi.testclient import TestClient
import pytest

from tests.conftest import TOKEN, bid, rec

PROTECTED = [
    ("GET", "/v1/changes", None),
    ("POST", "/v1/push", {"device": "mac-a", "records": [rec(1)]}),
    ("POST", "/v1/blobs/missing", {"ids": [bid(1)]}),
    ("GET", f"/v1/blobs/{bid(1)}", None),
]


def test_health_needs_no_token(anon: TestClient) -> None:
    response = anon.get("/v1/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert len(body["epoch"]) == 32


@pytest.mark.parametrize(("method", "path", "body"), PROTECTED)
@pytest.mark.parametrize(
    "authorization",
    [None, "Bearer wrong-token-0123456789", f"Basic {TOKEN}", f"Bearer {TOKEN}x", "Bearer"],
)
def test_protected_endpoints_need_the_token(
    anon: TestClient, method: str, path: str, body: object, authorization: str | None
) -> None:
    headers = {} if authorization is None else {"Authorization": authorization}
    response = anon.request(method, path, json=body, headers=headers)
    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"


def test_put_blob_needs_the_token(anon: TestClient) -> None:
    response = anon.put(f"/v1/blobs/{bid(1)}", content=b"sealed")
    assert response.status_code == 401
    # Nothing was stored.
    authed = anon.get(f"/v1/blobs/{bid(1)}", headers={"Authorization": f"Bearer {TOKEN}"})
    assert authed.status_code == 404


def test_token_is_case_sensitive_but_scheme_is_not(anon: TestClient) -> None:
    assert anon.get("/v1/changes", headers={"Authorization": f"bearer {TOKEN}"}).status_code == 200
    wrong = anon.get("/v1/changes", headers={"Authorization": f"Bearer {TOKEN.upper()}"})
    assert wrong.status_code == 401
