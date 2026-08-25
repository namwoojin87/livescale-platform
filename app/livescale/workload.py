import hashlib
import os
from collections.abc import Mapping

DEFAULT_WORK_ITERATIONS = 5_000
MAX_WORK_ITERATIONS = 1_000_000


def read_work_iterations(env: Mapping[str, str] | None = None) -> int:
    source = os.environ if env is None else env
    raw = source.get("WATCH_WORK_ITERATIONS", str(DEFAULT_WORK_ITERATIONS))

    try:
        iterations = int(raw)
    except ValueError as exc:
        raise ValueError("WATCH_WORK_ITERATIONS must be an integer") from exc

    if not 1 <= iterations <= MAX_WORK_ITERATIONS:
        raise ValueError(
            "WATCH_WORK_ITERATIONS must be between 1 and 1000000"
        )
    return iterations


def burn_cpu(iterations: int, seed: bytes = b"livescale") -> str:
    digest = seed
    for _ in range(iterations):
        digest = hashlib.sha256(digest + seed).digest()
    return digest.hex()
