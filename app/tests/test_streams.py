import pytest
from fastapi.testclient import TestClient

from livescale.main import create_app


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(work_iterations=1))


def test_lists_live_streams(client: TestClient) -> None:
    response = client.get("/streams")

    assert response.status_code == 200
    assert response.json() == [
        {"stream_id": 1, "title": "LCK FINAL", "status": "LIVE"},
        {"stream_id": 2, "title": "Live Concert", "status": "LIVE"},
    ]


def test_returns_stream_detail(client: TestClient) -> None:
    response = client.get("/streams/1")

    assert response.status_code == 200
    assert response.json() == {
        "stream_id": 1,
        "title": "LCK FINAL",
        "status": "LIVE",
    }


def test_missing_stream_returns_404(client: TestClient) -> None:
    response = client.get("/streams/999")

    assert response.status_code == 404
    assert response.json() == {"detail": "stream not found"}
