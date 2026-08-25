# LiveScale

LiveScale은 치지직과 같은 라이브 스트리밍 서비스에서 대형 이벤트가 시작될 때 발생할 수 있는 급격한 API 트래픽을 모티브로 한 2주 개인 인프라 프로젝트입니다. 실제 치지직의 내부 인프라를 재현하거나 단정하지 않으며, 영상 송출 대신 시청 진입 API를 대상으로 Terraform, Kubernetes HPA, 부하 테스트와 장애 복구를 실험합니다.

## 확인된 결과

| 실험 | 결과 |
|---|---|
| 애플리케이션 테스트 | 14개 통과 |
| Terraform | 5개 리소스 관리, 재계획 시 변경 없음 |
| 평상시 배치 | Worker 두 대에 Pod 1개씩 |
| k6 급증 테스트 | 115,904 요청, 실패율 0.00% |
| 응답시간 | p95 21.18ms, p99 31.52ms |
| HPA | 2 → 3 → 5 → 8 → 3 → 2 replicas |
| 첫 Scale-out | 테스트 시작 54.7초 후 |
| 최대 replica | 132.5초 후 8개 |
| Pod Self-Healing | 새 Pod 관찰 2.234초, 완전 복구 9.404초 |
| 장애 구간 요청 | 862 요청, 실패율 0.00% |

자세한 수치는 [HPA 실험 결과](docs/experiments/hpa-results.md)와 [Self-Healing 실험 결과](docs/experiments/self-healing-results.md)에 기록되어 있습니다.

## 아키텍처

```text
k6
 │
 ▼
Traefik Ingress :80
 │
 ▼
ClusterIP Service
 │
 ├──────────────┐
 ▼              ▼
API Pod         API Pod       ... 최대 8개
Worker 1        Worker 2
       ▲
       │ CPU metrics
Metrics Server ── HPA

Terraform ── Namespace / Deployment / Service / Ingress / HPA
```

기반 VM과 k3s는 고정 인프라로 취급하고, Terraform은 Kubernetes 애플리케이션 리소스를 관리합니다. VMware Workstation VM 생명주기는 Terraform 범위에서 제외했습니다.

| 역할 | 호스트명 | IP | OS |
|---|---|---:|---|
| Control Plane | `livescale-control` | `172.16.8.50` | Ubuntu 24.04.4 LTS |
| Worker 1 | `livescale-worker-1` | `172.16.8.51` | Ubuntu 24.04.4 LTS |
| Worker 2 | `livescale-worker-2` | `172.16.8.52` | Ubuntu 24.04.4 LTS |

클러스터 버전은 `k3s v1.36.3+k3s1`입니다. Control Plane에는 `NoSchedule` taint가 있어 일반 API Pod는 두 Worker에만 배치됩니다.

## API 범위

| 메서드와 경로 | 용도 |
|---|---|
| `GET /health` | liveness probe |
| `GET /ready` | readiness probe |
| `GET /streams` | 샘플 라이브 목록 |
| `GET /streams/{id}` | 샘플 스트림 상세 |
| `GET /streams/{id}/watch` | 시청 진입 응답과 제한된 CPU 연산 |

`/watch`는 영상을 반환하지 않습니다. `WATCH_WORK_ITERATIONS`만큼 SHA-256 연산을 수행해 HPA가 관찰할 CPU 부하를 만듭니다. 허용 범위는 1~1,000,000이고 배포 기본값은 5,000입니다.

## 저장소 구조

```text
app/                    FastAPI 소스, 테스트, Dockerfile
terraform/              Kubernetes 리소스 선언
loadtest/               k6 이벤트성 트래픽 시나리오
scripts/image/           이미지 빌드 및 세 노드 적재
scripts/verify/          배포 스모크 검증
scripts/experiments/     HPA 관찰 및 Pod 삭제 실험
docs/experiments/        실제 실험 결과
docs/superpowers/        승인된 설계와 구현 계획
```

## 버전과 준비물

- Python `3.12.10`
- FastAPI `0.141.1`, Uvicorn `0.52.3`
- pytest `9.1.1`, HTTPX2 `2.12.0`
- Terraform `1.15.9`
- HashiCorp Kubernetes provider `3.2.1`
- Docker Engine `29.6.0` on Control Plane
- k6 container `grafana/k6:2.1.0`
- Windows OpenSSH, `kubectl`, PowerShell

Terraform은 [공식 Kubernetes provider 흐름](https://developer.hashicorp.com/terraform/tutorials/kubernetes/kubernetes-provider)에 따라 기존 클러스터의 kubeconfig를 사용합니다. kubeconfig와 SSH 키는 Git에 포함하지 않습니다.

## 1. 애플리케이션 테스트

```powershell
python -m venv work/venv
work/venv/Scripts/python -m pip install -r app/requirements-dev.txt
$env:PYTHONPATH = (Resolve-Path app).Path
work/venv/Scripts/python -m pytest app/tests -v
```

Terraform CLI는 공식 checksum을 검증해 프로젝트 작업 폴더에 설치합니다.

```powershell
./scripts/setup/install-terraform.ps1 -Version 1.15.9
```

## 2. 컨테이너 이미지 적재

이미지는 외부 registry에 올리지 않고 Control Plane에서 빌드한 뒤 세 노드의 k3s containerd에 직접 가져옵니다.

```powershell
$password = Read-Host 'VM sudo password' -AsSecureString
./scripts/image/build-and-load.ps1 `
  -SshKey work/ssh/livescale_ed25519 `
  -KnownHosts work/ssh/known_hosts `
  -SudoPassword $password
```

스크립트는 다음을 보장합니다.

- 이미지 태그: `livescale-api:0.1.0`
- 세 노드에서 동일한 image digest 확인
- 임시 build context와 tar 삭제
- 작업 후 `docker.service`와 `docker.socket` 중지

## 3. 로컬 kubeconfig 준비

Control Plane의 kubeconfig를 안전한 임시 파일로 복사한 뒤 Windows로 가져옵니다. 아래 명령은 비밀번호를 파일에 기록하지 않고 대화형 sudo prompt를 사용합니다.

```powershell
ssh user1@172.16.8.50 `
  'sudo install -m 0644 /etc/rancher/k3s/k3s.yaml /tmp/livescale-kubeconfig.yaml'
scp user1@172.16.8.50:/tmp/livescale-kubeconfig.yaml work/kubeconfig-livescale.yaml
ssh user1@172.16.8.50 'sudo rm -f -- /tmp/livescale-kubeconfig.yaml'
kubectl config set-cluster default `
  --server=https://172.16.8.50:6443 `
  --kubeconfig=work/kubeconfig-livescale.yaml
kubectl --kubeconfig=work/kubeconfig-livescale.yaml get nodes
```

`work/kubeconfig-livescale.yaml`에는 관리자 인증서와 개인 키가 들어 있으므로 공유하거나 커밋하면 안 됩니다.

## 4. Terraform 배포

```powershell
$terraform = (Resolve-Path work/tools/terraform-1.15.9/terraform.exe).Path
$kubeconfig = (Resolve-Path work/kubeconfig-livescale.yaml).Path.Replace('\', '/')

& $terraform -chdir=terraform init
& $terraform -chdir=terraform fmt -check
& $terraform -chdir=terraform validate
& $terraform -chdir=terraform plan `
  -var="kubeconfig_path=$kubeconfig" `
  -out=../work/livescale.tfplan
& $terraform -chdir=terraform show -no-color ../work/livescale.tfplan
& $terraform -chdir=terraform apply ../work/livescale.tfplan
```

검토할 기본 변경은 다음 5개 리소스 생성입니다.

- `kubernetes_namespace_v1.livescale`
- `kubernetes_deployment_v1.api`
- `kubernetes_service_v1.api`
- `kubernetes_ingress_v1.api`
- `kubernetes_horizontal_pod_autoscaler_v2.api`

## 5. 배포 확인

```powershell
./scripts/verify/smoke.ps1 `
  -Kubeconfig work/kubeconfig-livescale.yaml `
  -TimeoutSeconds 180
```

직접 확인할 때는 Host 헤더를 지정합니다.

```powershell
Invoke-RestMethod http://172.16.8.50/health `
  -Headers @{Host='livescale.local'}
Invoke-RestMethod http://172.16.8.50/streams/1/watch `
  -Headers @{Host='livescale.local'}
```

## 6. HPA 급증 실험

Control Plane에 `loadtest/spike.js`를 복사하고 Docker 기반 k6를 실행합니다.

```bash
sudo systemctl start docker
sudo docker run --rm --network host \
  -v /tmp/livescale-k6:/scripts:ro \
  grafana/k6:2.1.0 run --quiet /scripts/spike.js
sudo systemctl stop docker.service docker.socket
```

동시에 Windows에서 HPA를 관찰합니다.

```powershell
./scripts/experiments/observe-hpa.ps1 `
  -Kubeconfig work/kubeconfig-livescale.yaml `
  -DurationSeconds 480 `
  -IntervalSeconds 5
```

기본 k6 임계값은 HTTP 실패율 1% 미만, p95 500ms 미만, check 성공률 99% 초과입니다.

## 7. Pod Self-Healing 실험

3 VU 부하를 60초 동안 실행한 뒤 별도 PowerShell에서 다음 명령을 실행합니다.

```powershell
./scripts/experiments/delete-pod.ps1 `
  -Kubeconfig work/kubeconfig-livescale.yaml `
  -TimeoutSeconds 120
```

스크립트는 삭제 전 UID 목록을 보관하고 기존에 없던 새 UID가 Ready가 됐는지 확인하므로 기존 Pod를 replacement로 잘못 판단하지 않습니다.

## 주요 Kubernetes 설정

```yaml
replicas: 2
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
hpa:
  minReplicas: 2
  maxReplicas: 8
  targetCPUUtilization: 60%
```

- Rolling Update: `maxUnavailable: 0`, `maxSurge: 1`
- Liveness: `/health`
- Readiness: `/ready`
- Topology spread: `kubernetes.io/hostname`
- Scale-down stabilization: 60초
- 컨테이너: UID 10001, non-root, read-only root filesystem

## 상태 확인 명령

```powershell
kubectl --kubeconfig=work/kubeconfig-livescale.yaml get nodes
kubectl --kubeconfig=work/kubeconfig-livescale.yaml get pods -n livescale -o wide
kubectl --kubeconfig=work/kubeconfig-livescale.yaml get hpa -n livescale
kubectl --kubeconfig=work/kubeconfig-livescale.yaml top pods -n livescale
```

## 문제 해결

- `ImagePullBackOff`: `build-and-load.ps1`을 다시 실행하고 두 Worker 모두에 이미지가 있는지 확인합니다.
- HPA `TARGETS`가 `<unknown>`: Metrics Server가 준비될 때까지 기다린 뒤 `kubectl top pods -n livescale`을 확인합니다.
- Ingress가 404: `Host: livescale.local` 헤더가 포함됐는지 확인합니다. Host 헤더가 없을 때 Traefik의 404는 정상입니다.
- Pod가 Control Plane에 배치됨: `livescale-control`의 `NoSchedule` taint가 유지되는지 확인합니다.
- Terraform provider 오류: `terraform init -upgrade=false`와 `.terraform.lock.hcl`의 `3.2.1` 고정을 확인합니다.

## 정리

Terraform이 관리하는 애플리케이션만 제거할 때는 반드시 destroy plan을 먼저 검토합니다.

```powershell
& $terraform -chdir=terraform plan -destroy `
  -var="kubeconfig_path=$kubeconfig" `
  -out=../work/livescale-destroy.tfplan
& $terraform -chdir=terraform show -no-color ../work/livescale-destroy.tfplan
& $terraform -chdir=terraform apply ../work/livescale-destroy.tfplan
```

이 명령은 기존 k3s 클러스터나 VM을 삭제하지 않고 Terraform이 관리하는 `livescale` 리소스만 제거합니다.

## README 체크리스트

- [x] 실제 치지직 내부 구조가 아닌 모티브 프로젝트임을 명시
- [x] API 단위 테스트
- [x] 재현 가능한 이미지 빌드·적재
- [x] Terraform format, validate, plan, apply
- [x] Deployment, Service, Ingress, HPA
- [x] requests/limits와 probes
- [x] k6 이벤트성 트래픽 테스트
- [x] HPA Scale-out/Scale-in 측정
- [x] Pod Self-Healing 측정
- [x] 자격 증명과 Terraform state 제외
- [x] 실험 결과 문서화
