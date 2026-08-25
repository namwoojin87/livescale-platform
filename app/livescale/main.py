import socket

from fastapi import FastAPI, HTTPException

from livescale.catalog import get_stream, list_streams
from livescale.workload import burn_cpu, read_work_iterations


def create_app(work_iterations: int | None = None) -> FastAPI:
    api = FastAPI(title="LiveScale API", version="0.1.0")
    configured_iterations = (
        read_work_iterations() if work_iterations is None else work_iterations
    )

    @api.get("/health")
    def health() -> dict[str, str]:
        return {"status": "live"}

    @api.get("/ready")
    def ready() -> dict[str, str]:
        return {"status": "ready"}

    @api.get("/streams")
    def streams() -> tuple[dict[str, object], ...]:
        return list_streams()

    @api.get("/streams/{stream_id}")
    def stream_detail(stream_id: int) -> dict[str, object]:
        stream = get_stream(stream_id)
        if stream is None:
            raise HTTPException(status_code=404, detail="stream not found")
        return stream

    @api.get("/streams/{stream_id}/watch")
    def watch_stream(stream_id: int) -> dict[str, object]:
        stream = get_stream(stream_id)
        if stream is None:
            raise HTTPException(status_code=404, detail="stream not found")

        return {
            "stream_id": stream["stream_id"],
            "status": stream["status"],
            "served_by": socket.gethostname(),
            "work_iterations": configured_iterations,
            "work_digest": burn_cpu(configured_iterations),
        }

    return api


app = create_app()
