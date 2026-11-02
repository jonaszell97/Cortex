from fastapi.testclient import TestClient
import pytest

from tests.conftest import bid


def test_missing_lists_unknown_ids_in_order_without_duplicates(client: TestClient) -> None:
    client.put(f"/v1/blobs/{bid(2)}", content=b"two")
    response = client.post("/v1/blobs/missing", json={"ids": [bid(3), bid(2), bid(1), bid(3)]})
    assert response.status_code == 200
    assert response.json()["missing"] == [bid(3), bid(1)]


def test_missing_with_no_ids(client: TestClient) -> None:
    assert client.post("/v1/blobs/missing", json={"ids": []}).json()["missing"] == []


def test_put_then_get(client: TestClient) -> None:
    data = bytes(range(256)) * 100
    response = client.put(
        f"/v1/blobs/{bid(1)}", content=data, headers={"Content-Type": "application/octet-stream"}
    )
    assert response.status_code == 200
    assert response.json()["stored"] is True
    fetched = client.get(f"/v1/blobs/{bid(1)}")
    assert fetched.status_code == 200
    assert fetched.headers["Content-Type"] == "application/octet-stream"
    assert fetched.content == data


def test_put_existing_blob_is_a_no_op(client: TestClient) -> None:
    client.put(f"/v1/blobs/{bid(1)}", content=b"first")
    response = client.put(f"/v1/blobs/{bid(1)}", content=b"second")
    assert response.status_code == 200
    assert response.json()["stored"] is False
    assert client.get(f"/v1/blobs/{bid(1)}").content == b"first"


def test_get_unknown_blob_is_404(client: TestClient) -> None:
    assert client.get(f"/v1/blobs/{bid(9)}").status_code == 404


def test_blob_ids_from_32_to_64_hex_chars(client: TestClient) -> None:
    for blob_id in ["a" * 32, "b" * 64]:
        assert client.put(f"/v1/blobs/{blob_id}", content=b"x").status_code == 200
        assert client.get(f"/v1/blobs/{blob_id}").content == b"x"


@pytest.mark.parametrize("blob_id", ["a" * 31, "a" * 65, "G" * 32, "A" * 32])
def test_invalid_blob_ids_are_rejected(client: TestClient, blob_id: str) -> None:
    assert client.put(f"/v1/blobs/{blob_id}", content=b"x").status_code == 422
    assert client.get(f"/v1/blobs/{blob_id}").status_code == 422
    response = client.post("/v1/blobs/missing", json={"ids": [blob_id]})
    assert response.status_code == 422
