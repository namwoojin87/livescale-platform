import argparse
import re
import subprocess
from pathlib import Path, PurePosixPath


SECRET_PATTERNS = {
    "private key": re.compile(
        r"-----BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----"
    ),
    "kubeconfig client key": re.compile(r"client-key" r"-data:\s*\S+"),
    "kubeconfig client certificate": re.compile(
        r"client-certificate" r"-data:\s*\S+"
    ),
    "k3s node token": re.compile(
        r"(?:node" r"-token|K10[0-9a-fA-F]{40,})"
    ),
    "known lab password": re.compile(
        r"ConvertTo-SecureString\s+['\"]user1['\"]"
    ),
}


def tracked_files(repository: Path) -> tuple[PurePosixPath, ...]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=repository,
        check=True,
        capture_output=True,
    )
    return tuple(
        PurePosixPath(path.decode("utf-8"))
        for path in result.stdout.split(b"\0")
        if path
    )


def is_runtime_artifact(path: PurePosixPath) -> bool:
    lowered_parts = tuple(part.lower() for part in path.parts)
    name = path.name.lower()
    return (
        any(part in {"work", "outputs", ".terraform"} for part in lowered_parts)
        or name.endswith((".tfstate", ".tfplan", ".kubeconfig"))
        or ".tfstate." in name
        or (name.startswith("kubeconfig") and name.endswith((".yaml", ".yml")))
    )


def scan(repository: Path) -> list[str]:
    findings: list[str] = []
    files = tracked_files(repository)

    for relative_path in files:
        if is_runtime_artifact(relative_path):
            findings.append(f"tracked runtime artifact: {relative_path.as_posix()}")

        full_path = repository / Path(*relative_path.parts)
        try:
            contents = full_path.read_text(encoding="utf-8", errors="ignore")
        except OSError as exc:
            findings.append(f"unreadable tracked file: {relative_path.as_posix()}: {exc}")
            continue

        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(contents):
                findings.append(
                    f"secret pattern ({label}): {relative_path.as_posix()}"
                )

    return findings


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reject tracked runtime artifacts and credential patterns."
    )
    parser.add_argument("--repo", default=".", help="Git repository to inspect.")
    repository = Path(parser.parse_args().repo).resolve()

    try:
        findings = scan(repository)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"repository_safety=error {exc}")
        return 2

    if findings:
        print("repository_safety=failed")
        for finding in findings:
            print(f"- {finding}")
        return 1

    print(f"repository_safety=passed tracked_files={len(tracked_files(repository))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
