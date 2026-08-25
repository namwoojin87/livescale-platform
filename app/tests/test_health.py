from fastapi.testclient import TestClient

from livescale.main import create_app


def test_health_reports_live() -> None:
    response = TestClient(create_app(work_iterations=1)).get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "live"}


def test_ready_reports_ready() -> None:
    response = TestClient(create_app(work_iterations=1)).get("/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
