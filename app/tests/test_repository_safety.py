import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SAFETY_SCRIPT = PROJECT_ROOT / "scripts" / "verify" / "repository_safety.py"


def run_git(repository: Path, *arguments: str) -> None:
    subprocess.run(
        ["git", *arguments],
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    )


def initialize_repository(repository: Path) -> None:
    run_git(repository, "init", "--quiet")
    run_git(repository, "config", "user.name", "CI Test")
    run_git(repository, "config", "user.email", "ci-test@example.invalid")


def run_safety_check(repository: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SAFETY_SCRIPT), "--repo", str(repository)],
        capture_output=True,
        text=True,
    )


def test_repository_safety_accepts_safe_tracked_files(tmp_path: Path) -> None:
    initialize_repository(tmp_path)
    (tmp_path / "README.md").write_text("# safe repository\n", encoding="utf-8")
    run_git(tmp_path, "add", "README.md")

    result = run_safety_check(tmp_path)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "repository_safety=passed" in result.stdout


def test_repository_safety_does_not_flag_its_own_rule_definitions(
    tmp_path: Path,
) -> None:
    initialize_repository(tmp_path)
    copied_script = tmp_path / "scripts" / "verify" / "repository_safety.py"
    copied_script.parent.mkdir(parents=True)
    copied_script.write_text(SAFETY_SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
    run_git(tmp_path, "add", "scripts/verify/repository_safety.py")

    result = run_safety_check(tmp_path)

    assert result.returncode == 0, result.stdout + result.stderr


def test_repository_safety_rejects_tracked_runtime_artifacts(tmp_path: Path) -> None:
    initialize_repository(tmp_path)
    runtime_file = tmp_path / "work" / "kubeconfig-livescale.yaml"
    runtime_file.parent.mkdir()
    runtime_file.write_text("not-a-real-kubeconfig\n", encoding="utf-8")
    run_git(tmp_path, "add", "--force", "work/kubeconfig-livescale.yaml")

    result = run_safety_check(tmp_path)

    assert result.returncode == 1
    assert "tracked runtime artifact" in result.stdout
    assert "work/kubeconfig-livescale.yaml" in result.stdout


def test_repository_safety_rejects_secret_patterns(tmp_path: Path) -> None:
    initialize_repository(tmp_path)
    (tmp_path / "notes.txt").write_text(
        "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nplaceholder\n",
        encoding="utf-8",
    )
    run_git(tmp_path, "add", "notes.txt")

    result = run_safety_check(tmp_path)

    assert result.returncode == 1
    assert "secret pattern" in result.stdout
    assert "notes.txt" in result.stdout
