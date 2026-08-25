import pytest
from fastapi.testclient import TestClient

from livescale.main import create_app
from livescale.workload import burn_cpu, read_work_iterations


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app(work_iterations=3))


def test_workload_has_known_digest() -> None:
    assert burn_cpu(3) == (
        "048b85cef2cccf111321fd5dcbd98a73940812720a3b37f8b53db7e96b429541"
    )


def test_work_iterations_default_to_5000() -> None:
    assert read_work_iterations({}) == 5_000


def test_work_iterations_accept_valid_override() -> None:
    assert read_work_iterations({"WATCH_WORK_ITERATIONS": "42"}) == 42


@pytest.mark.parametrize("raw", ["0", "-1", "1000001", "not-a-number"])
def test_rejects_invalid_work_iterations(raw: str) -> None:
    with pytest.raises(ValueError, match="WATCH_WORK_ITERATIONS"):
        read_work_iterations({"WATCH_WORK_ITERATIONS": raw})


def test_watch_returns_serving_pod(client: TestClient) -> None:
    response = client.get("/streams/1/watch")

    assert response.status_code == 200
    body = response.json()
    assert set(body) == {
        "stream_id",
        "status",
        "served_by",
        "work_iterations",
        "work_digest",
    }
    assert body["stream_id"] == 1
    assert body["status"] == "LIVE"
    assert body["served_by"]
    assert body["work_iterations"] == 3
    assert body["work_digest"] == (
        "048b85cef2cccf111321fd5dcbd98a73940812720a3b37f8b53db7e96b429541"
    )


def test_watch_missing_stream_returns_404(client: TestClient) -> None:
    response = client.get("/streams/999/watch")

    assert response.status_code == 404
    assert response.json() == {"detail": "stream not found"}
