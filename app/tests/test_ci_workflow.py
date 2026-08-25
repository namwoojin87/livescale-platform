import re
from pathlib import Path

import yaml


PROJECT_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = PROJECT_ROOT / ".github" / "workflows" / "ci.yml"
PINNED_ACTION = re.compile(r"^[^\s@]+@[0-9a-f]{40}$")


def load_workflow() -> dict[str, object]:
    assert WORKFLOW_PATH.is_file(), "CI workflow is missing"
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def assert_actions_are_commit_pinned(steps: list[dict[str, object]]) -> None:
    actions = [str(step["uses"]) for step in steps if "uses" in step]
    assert actions
    assert all(PINNED_ACTION.fullmatch(action) for action in actions)


def test_ci_runs_for_main_pull_requests_and_pushes_with_minimum_permissions() -> None:
    workflow = load_workflow()

    assert workflow["name"] == "CI"
    assert workflow["on"] == {
        "pull_request": {"branches": ["main"]},
        "push": {"branches": ["main"]},
    }
    assert workflow["permissions"] == {"contents": "read"}
    assert workflow["concurrency"] == {
        "group": "${{ github.workflow }}-${{ github.ref }}",
        "cancel-in-progress": "true",
    }


def test_ci_exposes_three_independent_verification_jobs() -> None:
    workflow = load_workflow()
    jobs = workflow["jobs"]

    assert set(jobs) == {
        "application-tests",
        "terraform-static",
        "repository-safety",
    }
    assert all(job["runs-on"] == "ubuntu-latest" for job in jobs.values())
    assert all(job["timeout-minutes"] == "10" for job in jobs.values())
    for job in jobs.values():
        assert_actions_are_commit_pinned(job["steps"])

    application_commands = "\n".join(
        str(step.get("run", "")) for step in jobs["application-tests"]["steps"]
    )
    assert "python -m pip install -r app/requirements-dev.txt" in application_commands
    assert "python -m pytest -q" in application_commands

    terraform_commands = "\n".join(
        str(step.get("run", "")) for step in jobs["terraform-static"]["steps"]
    )
    assert "terraform fmt -check -recursive" in terraform_commands
    assert "terraform -chdir=terraform init -backend=false" in terraform_commands
    assert "terraform -chdir=terraform validate" in terraform_commands

    safety_commands = "\n".join(
        str(step.get("run", "")) for step in jobs["repository-safety"]["steps"]
    )
    assert "python scripts/verify/repository_safety.py" in safety_commands
