STREAMS: tuple[dict[str, object], ...] = (
    {"stream_id": 1, "title": "LCK FINAL", "status": "LIVE"},
    {"stream_id": 2, "title": "Live Concert", "status": "LIVE"},
)


def list_streams() -> tuple[dict[str, object], ...]:
    return STREAMS


def get_stream(stream_id: int) -> dict[str, object] | None:
    return next(
        (stream for stream in STREAMS if stream["stream_id"] == stream_id),
        None,
    )
