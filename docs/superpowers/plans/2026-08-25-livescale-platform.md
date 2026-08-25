# LiveScale Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, deploy, and verify a FastAPI workload on the existing three-node k3s cluster so Terraform, HPA, k6 traffic spikes, and Pod self-healing can be demonstrated from one repository.

**Architecture:** The existing VMware Workstation VMs and k3s installation remain fixed infrastructure. A versioned local container image is built on the control VM and imported into each node; Terraform then manages the Kubernetes application resources through a local kubeconfig. k6 drives the Traefik ingress while scripts record scaling and recovery evidence.

**Tech Stack:** Python 3.12.10, FastAPI 0.141.1, Uvicorn 0.52.3, pytest 9.1.1, HTTPX2 2.12.0, Docker Engine 29.6.0, Terraform 1.15.9, HashiCorp Kubernetes provider 3.2.1, k3s/Kubernetes v1.36.3+k3s1, k6 2.1.0, PowerShell 7.

**Spec:** `docs/superpowers/specs/2026-08-25-livescale-platform-design.md`

## Global Constraints

- State clearly that LiveScale is inspired by event traffic patterns for a CHZZK-like streaming service and does not claim knowledge of CHZZK's internal infrastructure.
- Treat `livescale-control` (`172.16.8.50`), `livescale-worker-1` (`172.16.8.51`), and `livescale-worker-2` (`172.16.8.52`) as fixed infrastructure.
- Keep `livescale-control` tainted `node-role.kubernetes.io/control-plane=true:NoSchedule`; application Pods must run on the workers.
- Use image `livescale-api:0.1.0`, namespace `livescale`, Service `livescale-api`, Ingress host `livescale.local`, and container port `8000`.
- Use two initial replicas, HPA minimum 2, maximum 8, CPU target 60%, CPU request/limit `100m`/`500m`, and memory request/limit `128Mi`/`256Mi`.
- Do not commit kubeconfig, SSH keys, passwords, join tokens, Terraform state, plan files, virtual environments, test caches, image archives, or raw load-test output.
- Implement all Python behavior test-first and verify each test fails for the intended missing behavior before adding production code.
- Keep the Docker service disabled outside image build and load-test execution.

---

### Task 1: Repository hygiene and health endpoints

**Files:**
- Create: `.gitignore`
- Create: `app/requirements.txt`
- Create: `app/requirements-dev.txt`
- Create: `app/livescale/__init__.py`
- Create: `app/livescale/main.py`
- Create: `app/tests/test_health.py`

**Interfaces:**
- Consumes: Python 3.12 from the Windows host.
- Produces: `livescale.main.create_app(work_iterations: int | None = None) -> FastAPI` and module-level `app`.

- [ ] **Step 1: Add repository exclusions and pinned dependencies**

```text
# .gitignore essentials
work/
outputs/
.venv/
__pycache__/
.pytest_cache/
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.tar
*.kubeconfig
kubeconfig*.yaml
```

`app/requirements.txt` pins `fastapi==0.141.1` and `uvicorn==0.52.3`. `app/requirements-dev.txt` includes `-r requirements.txt`, `httpx2==2.12.0`, and `pytest==9.1.1`. Starlette 1.6 prefers HTTPX2 for TestClient and emits a deprecation warning when it falls back to HTTPX.

- [ ] **Step 2: Create and populate the isolated test environment**

Run:

```powershell
python -m venv work/venv
work/venv/Scripts/python -m pip install --upgrade pip
work/venv/Scripts/python -m pip install -r app/requirements-dev.txt
```

Expected: installation exits 0 without modifying global Python packages.

- [ ] **Step 3: Write failing health endpoint tests**

```python
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
```

- [ ] **Step 4: Run the tests and verify RED**

Run:

```powershell
$env:PYTHONPATH = 'app'
work/venv/Scripts/python -m pytest app/tests/test_health.py -v
```

Expected: collection fails because `livescale.main` does not exist.

- [ ] **Step 5: Implement the minimal application factory and endpoints**

```python
from fastapi import FastAPI


def create_app(work_iterations: int | None = None) -> FastAPI:
    api = FastAPI(title="LiveScale API", version="0.1.0")

    @api.get("/health")
    def health() -> dict[str, str]:
        return {"status": "live"}

    @api.get("/ready")
    def ready() -> dict[str, str]:
        return {"status": "ready"}

    return api


app = create_app()
```

- [ ] **Step 6: Run the focused and complete test suite**

Run: `$env:PYTHONPATH='app'; work/venv/Scripts/python -m pytest app/tests -v`

Expected: 2 passed.

- [ ] **Step 7: Commit**

```powershell
git add .gitignore app/requirements.txt app/requirements-dev.txt app/livescale app/tests/test_health.py
git commit -m "feat: add LiveScale health API"
```

### Task 2: Stream catalog API

**Files:**
- Create: `app/livescale/catalog.py`
- Create: `app/tests/test_streams.py`
- Modify: `app/livescale/main.py`

**Interfaces:**
- Consumes: `create_app()` from Task 1.
- Produces: `list_streams() -> tuple[dict[str, object], ...]`, `get_stream(stream_id: int) -> dict[str, object] | None`, `GET /streams`, and `GET /streams/{stream_id}`.

- [ ] **Step 1: Write failing catalog endpoint tests**

```python
def test_lists_live_streams(client: TestClient) -> None:
    response = client.get("/streams")
    assert response.status_code == 200
    assert response.json()[0] == {
        "stream_id": 1,
        "title": "LCK FINAL",
        "status": "LIVE",
    }


def test_returns_stream_detail(client: TestClient) -> None:
    response = client.get("/streams/1")
    assert response.status_code == 200
    assert response.json()["title"] == "LCK FINAL"


def test_missing_stream_returns_404(client: TestClient) -> None:
    response = client.get("/streams/999")
    assert response.status_code == 404
    assert response.json() == {"detail": "stream not found"}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `$env:PYTHONPATH='app'; work/venv/Scripts/python -m pytest app/tests/test_streams.py -v`

Expected: all three assertions fail with `404 Not Found` because the routes do not exist.

- [ ] **Step 3: Implement the immutable catalog and routes**

```python
STREAMS = (
    {"stream_id": 1, "title": "LCK FINAL", "status": "LIVE"},
    {"stream_id": 2, "title": "Live Concert", "status": "LIVE"},
)


def list_streams() -> tuple[dict[str, object], ...]:
    return STREAMS


def get_stream(stream_id: int) -> dict[str, object] | None:
    return next((stream for stream in STREAMS if stream["stream_id"] == stream_id), None)
```

Register `/streams` and `/streams/{stream_id}` in `create_app()` and raise `HTTPException(status_code=404, detail="stream not found")` for an unknown ID.

- [ ] **Step 4: Run all application tests**

Run: `$env:PYTHONPATH='app'; work/venv/Scripts/python -m pytest app/tests -v`

Expected: 5 passed.

- [ ] **Step 5: Commit**

```powershell
git add app/livescale/catalog.py app/livescale/main.py app/tests/test_streams.py
git commit -m "feat: add stream catalog endpoints"
```

### Task 3: Deterministic watch workload

**Files:**
- Create: `app/livescale/workload.py`
- Create: `app/tests/test_watch.py`
- Modify: `app/livescale/main.py`

**Interfaces:**
- Consumes: `get_stream()` and `create_app()` from Tasks 1-2.
- Produces: `read_work_iterations(env: Mapping[str, str] | None = None) -> int`, `burn_cpu(iterations: int, seed: bytes = b"livescale") -> str`, and `GET /streams/{stream_id}/watch`.

- [ ] **Step 1: Write failing workload tests**

```python
def test_workload_is_deterministic() -> None:
    assert burn_cpu(3) == burn_cpu(3)


@pytest.mark.parametrize("raw", ["0", "-1", "1000001", "not-a-number"])
def test_rejects_invalid_work_iterations(raw: str) -> None:
    with pytest.raises(ValueError, match="WATCH_WORK_ITERATIONS"):
        read_work_iterations({"WATCH_WORK_ITERATIONS": raw})


def test_watch_returns_serving_pod(client: TestClient) -> None:
    response = client.get("/streams/1/watch")
    assert response.status_code == 200
    body = response.json()
    assert body["stream_id"] == 1
    assert body["status"] == "LIVE"
    assert body["work_iterations"] == 3
    assert body["served_by"]
    assert len(body["work_digest"]) == 64
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `$env:PYTHONPATH='app'; work/venv/Scripts/python -m pytest app/tests/test_watch.py -v`

Expected: collection fails because `livescale.workload` does not exist.

- [ ] **Step 3: Implement bounded settings and hash work**

```python
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
        raise ValueError("WATCH_WORK_ITERATIONS must be between 1 and 1000000")
    return iterations


def burn_cpu(iterations: int, seed: bytes = b"livescale") -> str:
    digest = seed
    for _ in range(iterations):
        digest = hashlib.sha256(digest + seed).digest()
    return digest.hex()
```

Use `socket.gethostname()` for `served_by`. `create_app(work_iterations=None)` reads the environment once; tests pass `3` to stay fast.

- [ ] **Step 4: Run all tests and verify GREEN**

Run: `$env:PYTHONPATH='app'; work/venv/Scripts/python -m pytest app/tests -v`

Expected: all tests pass with no warnings.

- [ ] **Step 5: Commit**

```powershell
git add app/livescale/workload.py app/livescale/main.py app/tests/test_watch.py
git commit -m "feat: add CPU-bound watch endpoint"
```

### Task 4: Container image and node image loader

**Files:**
- Create: `app/Dockerfile`
- Create: `app/.dockerignore`
- Create: `scripts/image/build-and-load.ps1`

**Interfaces:**
- Consumes: tested `app/` package, project-local SSH private key and known-hosts file.
- Produces: image `docker.io/library/livescale-api:0.1.0` in the k3s containerd image store on all three nodes.

- [ ] **Step 1: Add a non-root, health-checked Dockerfile**

```dockerfile
FROM python:3.12.10-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN groupadd --gid 10001 livescale \
    && useradd --uid 10001 --gid 10001 --no-create-home livescale
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY livescale ./livescale
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]
CMD ["uvicorn", "livescale.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

- [ ] **Step 2: Implement the PowerShell loader with explicit targets**

The script accepts `-SshKey`, `-KnownHosts`, and a `SecureString -SudoPassword`; it copies only `app/`, starts Docker on `172.16.8.50`, builds and saves the image, copies the archive through the local `work/` directory, imports it with `k3s ctr images import` on `.50`, `.51`, and `.52`, verifies the image name on every node, removes exact temporary paths, and stops Docker in a `finally` block.

Run static parsing before execution:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path scripts/image/build-and-load.ps1),
  [ref]$null,
  [ref]$errors
) | Out-Null
if ($errors.Count) { throw $errors }
```

- [ ] **Step 3: Execute the loader and inspect every node**

Run:

```powershell
$password = Read-Host 'VM sudo password' -AsSecureString
./scripts/image/build-and-load.ps1 -SshKey work/ssh/livescale_ed25519 `
  -KnownHosts work/ssh/known_hosts -SudoPassword $password
```

Expected: all three nodes report `docker.io/library/livescale-api:0.1.0` and the control VM reports Docker `inactive` after cleanup.

- [ ] **Step 4: Commit**

```powershell
git add app/Dockerfile app/.dockerignore scripts/image/build-and-load.ps1
git commit -m "build: add reproducible cluster image loader"
```

### Task 5: Terraform Kubernetes resources

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/providers.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/main.tf`
- Create: `terraform/outputs.tf`
- Create: `terraform/terraform.tfvars.example`

**Interfaces:**
- Consumes: an absolute `kubeconfig_path` and preloaded image `livescale-api:0.1.0`.
- Produces: Namespace, Deployment, Service, Ingress, and HPA named according to the global constraints.

- [ ] **Step 1: Pin Terraform and the Kubernetes provider**

```hcl
terraform {
  required_version = "= 1.15.9"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
  }
}
```

Configure the provider with `config_path = var.kubeconfig_path` and define validated variables for image, ingress host, replica limits, CPU target, and work iterations.

- [ ] **Step 2: Define the typed Kubernetes resources**

Use `kubernetes_namespace_v1`, `kubernetes_deployment_v1`, `kubernetes_service_v1`, and `kubernetes_ingress_v1`. The Deployment includes probes, resources, rolling-update limits, `WATCH_WORK_ITERATIONS`, and a `topology_spread_constraint` keyed by `kubernetes.io/hostname`.

- [ ] **Step 3: Define HPA with the provider's typed v2 resource**

```hcl
resource "kubernetes_horizontal_pod_autoscaler_v2" "api" {
  metadata {
    name      = "livescale-api"
    namespace = kubernetes_namespace_v1.livescale.metadata[0].name
  }
  spec {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.api.metadata[0].name
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.cpu_target_percent
        }
      }
    }
  }
}
```

- [ ] **Step 4: Export a private kubeconfig and install Terraform locally**

Fetch `/etc/rancher/k3s/k3s.yaml` through the existing SSH key, replace only `https://127.0.0.1:6443` with `https://172.16.8.50:6443`, and save it as ignored `work/kubeconfig-livescale.yaml`. Download Terraform 1.15.9 for Windows AMD64 plus the official SHA256SUMS file, verify the zip hash from that file, and expand `terraform.exe` into ignored `work/tools/terraform-1.15.9/`.

- [ ] **Step 5: Format and initialize**

Run:

```powershell
$terraform = Resolve-Path work/tools/terraform-1.15.9/terraform.exe
& $terraform -chdir=terraform fmt -check
& $terraform -chdir=terraform init
& $terraform -chdir=terraform validate
```

Expected: all commands exit 0 and `.terraform.lock.hcl` pins provider 3.2.1.

- [ ] **Step 6: Commit**

```powershell
git add terraform .gitignore
git commit -m "feat: manage LiveScale workload with Terraform"
```

### Task 6: Deploy and smoke-test the application

**Files:**
- Create: `scripts/verify/smoke.ps1`
- Modify: `terraform/.terraform.lock.hcl` if generated by init.

**Interfaces:**
- Consumes: Terraform configuration, kubeconfig, and node-local image.
- Produces: a healthy two-Pod LiveScale deployment reachable through Traefik.

- [ ] **Step 1: Create and review a saved Terraform plan**

Run:

```powershell
$kubeconfig = (Resolve-Path work/kubeconfig-livescale.yaml).Path
& $terraform -chdir=terraform plan -var="kubeconfig_path=$kubeconfig" `
  -out=../work/livescale.tfplan
& $terraform -chdir=terraform show -no-color ../work/livescale.tfplan
```

Expected: five resources to add and no destroy operations.

- [ ] **Step 2: Write and run a failing-first smoke verifier**

Before apply, run the verifier and confirm it fails because `livescale` does not exist. After apply it must check rollout completion, exactly two initial Ready Pods, distinct worker hostnames, HPA target availability, and the following requests with `Host: livescale.local`:

```powershell
Invoke-RestMethod -Uri 'http://172.16.8.50/health' -Headers @{Host='livescale.local'}
Invoke-RestMethod -Uri 'http://172.16.8.50/streams' -Headers @{Host='livescale.local'}
Invoke-RestMethod -Uri 'http://172.16.8.50/streams/1/watch' -Headers @{Host='livescale.local'}
```

- [ ] **Step 3: Apply the reviewed plan**

Run: `& $terraform -chdir=terraform apply -auto-approve ../work/livescale.tfplan`

Expected: Namespace, Deployment, Service, Ingress, and HPA are created.

- [ ] **Step 4: Run the verifier after apply**

Expected: rollout succeeds, Pods are on `.51` and `.52`, API responses are valid, and HPA reports CPU utilization rather than `<unknown>`.

- [ ] **Step 5: Commit**

```powershell
git add scripts/verify/smoke.ps1 terraform/.terraform.lock.hcl
git commit -m "test: add deployed workload smoke checks"
```

### Task 7: k6 spike and HPA evidence

**Files:**
- Create: `loadtest/spike.js`
- Create: `scripts/experiments/observe-hpa.ps1`
- Create: `docs/experiments/hpa-results.md`

**Interfaces:**
- Consumes: Ingress URL and HPA-managed deployment.
- Produces: k6 threshold result, timestamped HPA replica observations, and a concise experiment report.

- [ ] **Step 1: Implement the pinned k6 scenario**

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 5 },
    { duration: '60s', target: 10 },
    { duration: '60s', target: 100 },
    { duration: '180s', target: 100 },
    { duration: '60s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const response = http.get('http://172.16.8.50/streams/1/watch', {
    headers: { Host: 'livescale.local' },
  });
  check(response, { 'watch returns 200': (res) => res.status === 200 });
  sleep(0.2);
}
```

- [ ] **Step 2: Validate script syntax using k6 2.1.0**

Start Docker on the control VM, copy `spike.js`, and run:

```bash
docker run --rm -v /tmp/livescale-k6:/scripts grafana/k6:2.1.0 inspect /scripts/spike.js
```

Expected: parsed options show the five stages and both thresholds.

- [ ] **Step 3: Record HPA observations while k6 runs**

`observe-hpa.ps1` samples every five seconds and writes timestamp, current CPU target, current replicas, desired replicas, and Ready Pod count into ignored `work/results/hpa-observations.csv`. It also prints scale-out and scale-in milestones to the console.

- [ ] **Step 4: Execute the full spike test**

Run k6 on the control VM and the observer on Windows. Expected: k6 exits 0, HPA rises above two replicas, no Pod becomes unhealthy, and HPA later returns to two replicas. If HPA cannot rise, preserve the failed evidence, change only `work_iterations`, apply a reviewed Terraform plan, and rerun once.

- [ ] **Step 5: Write the evidence report**

Record exact run time, k6 version, VU profile, failure rate, p95/p99, peak replicas, first scale-out delay, and scale-in delay in `docs/experiments/hpa-results.md`; include the command used to reproduce the test.

- [ ] **Step 6: Commit**

```powershell
git add loadtest/spike.js scripts/experiments/observe-hpa.ps1 docs/experiments/hpa-results.md
git commit -m "test: document HPA response to spike traffic"
```

### Task 8: Pod self-healing experiment

**Files:**
- Create: `scripts/experiments/delete-pod.ps1`
- Create: `docs/experiments/self-healing-results.md`

**Interfaces:**
- Consumes: a healthy two-replica Deployment and kubeconfig.
- Produces: measured replacement time and evidence that the Deployment returned to its desired replica count.

- [ ] **Step 1: Implement explicit Pod deletion and recovery measurement**

The script selects one Pod by `app.kubernetes.io/name=livescale-api`, records its UID and node, deletes that exact Pod, waits until a different UID is Ready, then verifies all desired replicas are Available. It writes timestamped events to ignored `work/results/self-healing.json` and exits nonzero if recovery exceeds 120 seconds.

- [ ] **Step 2: Run low-load traffic during deletion**

Run a 60-second, 10-VU k6 test with the same URL and thresholds. Ten seconds after traffic starts, execute `delete-pod.ps1`. Expected: a replacement Pod becomes Ready, desired replica count is restored, and HTTP failures remain under 1%.

- [ ] **Step 3: Document exact evidence**

Record deleted Pod name/UID/node, replacement Pod name/UID/node, time to Ready, k6 failure rate, and final replica status in `docs/experiments/self-healing-results.md`.

- [ ] **Step 4: Commit**

```powershell
git add scripts/experiments/delete-pod.ps1 docs/experiments/self-healing-results.md
git commit -m "test: document Pod self-healing behavior"
```

### Task 9: README and complete verification

**Files:**
- Create: `README.md`
- Modify: files found inconsistent during verification.

**Interfaces:**
- Consumes: all preceding source, infrastructure, and evidence artifacts.
- Produces: a reproducible user-facing project entry point.

- [ ] **Step 1: Write the README**

Include the motif disclaimer, architecture, node table, repository tree, prerequisites, test commands, image load command, Terraform plan/apply/destroy workflow, smoke checks, k6 procedure, self-healing procedure, expected results, actual evidence links, troubleshooting, cleanup, and security notes. Do not include passwords, keys, tokens, or kubeconfig content.

- [ ] **Step 2: Run the fresh verification matrix**

```powershell
$env:PYTHONPATH='app'
work/venv/Scripts/python -m pytest app/tests -v
& $terraform -chdir=terraform fmt -check
& $terraform -chdir=terraform validate
./scripts/verify/smoke.ps1 -Kubeconfig work/kubeconfig-livescale.yaml
git diff --check
git status --short
```

Expected: tests pass with no warnings, Terraform formatting and validation exit 0, smoke checks pass, no whitespace errors occur, and only intended user artifacts remain untracked.

- [ ] **Step 3: Confirm live cluster state**

Run `kubectl get nodes`, `kubectl get pods -n livescale -o wide`, `kubectl get hpa -n livescale`, `kubectl top pods -n livescale`, and the three Ingress requests. Confirm three Ready nodes, healthy Pods on both workers, known HPA metrics, and valid API responses.

- [ ] **Step 4: Commit**

```powershell
git add README.md
git commit -m "docs: add LiveScale reproduction guide"
```

- [ ] **Step 5: Review commit history and working tree**

Run: `git log --oneline --decorate -10; git status --short --branch`

Expected: focused commits for design, API, container, Terraform, experiments, and README; `work/` and `outputs/` remain ignored and no credential is tracked.
