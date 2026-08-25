# LiveScale 실험 플랫폼 설계

## 1. 목적

LiveScale은 치지직과 같은 라이브 스트리밍 서비스에서 대형 이벤트가 시작될 때 발생할 수 있는 급격한 API 트래픽을 모티브로 한 개인 인프라 프로젝트다. 실제 치지직의 내부 구조를 재현하거나 단정하지 않으며, 영상 송출·트랜스코딩 대신 시청 진입 API의 부하와 Kubernetes의 확장·복구 동작을 실험한다.

이번 구현의 완료 조건은 다음과 같다.

- 세 노드 k3s 클러스터에 샘플 API가 두 개 이상의 Pod로 배포된다.
- 외부 요청이 Traefik Ingress를 통해 API에 도달한다.
- CPU 부하가 증가하면 HPA가 Pod를 확장하고, 부하 종료 후 축소한다.
- 실행 중인 Pod 하나를 삭제해도 Deployment가 복구하며 요청 성공률이 유지된다.
- 애플리케이션, Terraform, k6와 검증 절차를 저장소에서 재실행할 수 있다.

## 2. 인프라 경계

기존 VMware Workstation VM 세 대와 설치된 k3s는 이 프로젝트의 고정 기반 인프라로 취급한다.

| 역할 | 호스트명 | IP |
|---|---|---:|
| Control Plane | `livescale-control` | `172.16.8.50` |
| Worker 1 | `livescale-worker-1` | `172.16.8.51` |
| Worker 2 | `livescale-worker-2` | `172.16.8.52` |

Terraform은 로컬 VMware VM의 생명주기를 관리하지 않는다. VMware Workstation에는 이 프로젝트가 의존할 만한 공식 HashiCorp VM provider가 없고, 비공식 provider를 핵심 경로에 넣으면 2주 프로젝트의 재현성이 provider 상태에 좌우되기 때문이다.

역할은 다음과 같이 분리한다.

- 설치 스크립트: VM 운영체제와 k3s 초기화 절차를 재실행 가능한 형태로 보존한다.
- 이미지 로드 스크립트: 샘플 API 이미지를 빌드하고 두 Worker의 k3s containerd에 동일한 태그로 적재한다.
- Terraform: Namespace, Deployment, Service, Ingress, HPA를 선언하고 변경 이력을 관리한다.
- Kubernetes: 애플리케이션 스케줄링, 상태 확인, 확장, 장애 복구를 담당한다.
- k6: 평상시·급증·회복 트래픽을 재현하고 응답 성능을 측정한다.

## 3. 저장소 구조

```text
app/
  livescale/
    __init__.py
    main.py
    catalog.py
    workload.py
  tests/
    test_health.py
    test_streams.py
    test_watch.py
  requirements.txt
  requirements-dev.txt
  Dockerfile
  .dockerignore

terraform/
  versions.tf
  providers.tf
  variables.tf
  main.tf
  outputs.tf
  terraform.tfvars.example

loadtest/
  spike.js

scripts/
  image/
    build-and-load.ps1
  experiments/
    observe-hpa.ps1
    delete-pod.ps1
  verify/
    smoke.ps1

docs/
  superpowers/
    specs/
    plans/
  experiments/
    hpa-results.md
    self-healing-results.md

.gitignore
README.md
```

애플리케이션 코드, 인프라 선언, 실험 스크립트와 결과 문서를 분리한다. kubeconfig, SSH 키, Terraform state, 테스트 결과 원본처럼 자격 증명이나 로컬 상태가 포함될 수 있는 파일은 저장소에 넣지 않는다.

## 4. 샘플 API

애플리케이션은 Python 3.12와 FastAPI를 사용한다. 상태는 메모리에 고정된 샘플 스트림 목록만 사용하며 데이터베이스는 두지 않는다.

| 메서드와 경로 | 동작 |
|---|---|
| `GET /health` | liveness 확인용 `200 OK` |
| `GET /ready` | readiness 확인용 `200 OK` |
| `GET /streams` | 샘플 라이브 스트림 목록 반환 |
| `GET /streams/{stream_id}` | 스트림 상세 반환, 없는 ID는 `404` |
| `GET /streams/{stream_id}/watch` | 시청 진입 응답과 제한된 CPU 연산 수행 |

`/watch`는 영상 데이터를 반환하지 않는다. 환경 변수 `WATCH_WORK_ITERATIONS`로 정한 횟수만큼 결정적인 해시 연산을 수행해 CPU 사용량을 만든다. 응답에는 `stream_id`, `status`, `served_by`, `work_iterations`를 포함해 여러 Pod로 분산되는 모습을 확인할 수 있게 한다. 반복 횟수는 음수나 무제한 사용자 입력을 받지 않고 배포 설정으로만 제어한다.

애플리케이션 오류 응답은 FastAPI의 표준 JSON 형식을 사용한다. 스트림 미존재 외의 영속 데이터 오류, 인증, 결제, 채팅은 구현하지 않는다.

## 5. 컨테이너 이미지 공급

외부 레지스트리 계정과 비밀 정보를 요구하지 않도록 `livescale-api:0.1.0` 이미지를 로컬에서 만든 뒤 두 Worker에 직접 적재한다.

`scripts/image/build-and-load.ps1`은 다음 순서를 수행한다.

1. Control Plane의 Docker 서비스를 일시적으로 시작한다.
2. 저장소의 `app/`을 전송해 이미지를 빌드한다.
3. 이미지를 tar 파일로 저장한다.
4. Control Plane과 두 Worker에서 `k3s ctr images import`로 가져온다.
5. 각 노드에 동일한 이미지 ID가 있는지 확인한다.
6. 임시 tar와 원격 빌드 디렉터리를 삭제하고 Docker 서비스를 다시 중지한다.

Deployment는 `imagePullPolicy: IfNotPresent`를 사용한다. 이미지 태그를 바꾸지 않은 채 내용을 덮어쓰지 않으며, 변경할 때마다 버전 태그를 증가시킨다.

## 6. Terraform과 Kubernetes 구성

Terraform은 로컬 kubeconfig 경로를 입력받아 현재 k3s API에 연결한다. 자격 증명 자체를 변수 기본값이나 state에 기록하지 않는다.

관리 리소스는 다음과 같다.

- Namespace: `livescale`
- Deployment: `livescale-api`
- Service: `livescale-api`, `ClusterIP`, 서비스 포트 80에서 컨테이너 포트 8000으로 전달
- Ingress: `livescale-api`, IngressClass `traefik`, 호스트 `livescale.local`, 경로 `/`
- HPA: `autoscaling/v2`, CPU 평균 사용률 기준

Deployment 기본값은 다음과 같다.

```yaml
replicas: 2
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
livenessProbe:
  httpGet:
    path: /health
    port: 8000
readinessProbe:
  httpGet:
    path: /ready
    port: 8000
```

Pod에는 Worker 두 대에 고르게 퍼지도록 `kubernetes.io/hostname` 기준 topology spread constraint를 적용한다. Control Plane에는 기존 `NoSchedule` taint가 있으므로 일반 애플리케이션 Pod는 Worker에만 배치한다. 롤링 업데이트는 `maxUnavailable: 0`, `maxSurge: 1`로 설정한다.

HPA 기본값은 다음과 같다.

- `minReplicas: 2`
- `maxReplicas: 8`
- CPU 평균 사용률 목표: `60%`
- 확장은 즉시 반응하도록 안정화 대기 시간을 두지 않는다.
- 축소는 짧은 변동으로 인한 반복 증감을 줄이기 위해 60초 안정화 시간을 둔다.

Terraform 출력에는 Namespace, Service 이름, Ingress 호스트와 확인 명령만 제공한다. kubeconfig 내용이나 토큰은 출력하지 않는다.

## 7. k6 부하 테스트

`loadtest/spike.js`는 `Host: livescale.local` 헤더를 포함해 `http://172.16.8.50/streams/1/watch`를 호출한다.

단계는 다음과 같다.

1. 워밍업: 30초 동안 5 VU
2. 평상시: 60초 동안 10 VU
3. 급증: 60초 동안 10 VU에서 100 VU로 증가
4. 이벤트 유지: 180초 동안 100 VU
5. 회복: 60초 동안 100 VU에서 0 VU로 감소

기본 임계값은 HTTP 실패율 1% 미만, p95 응답시간 500ms 미만이다. 첫 실행에서 한 VM의 CPU가 포화되어 목표 자체를 측정할 수 없으면 VU 수가 아니라 `WATCH_WORK_ITERATIONS`를 조정하고, 변경값과 이유를 실험 문서에 기록한다.

관찰 항목은 다음과 같다.

- k6 처리량, 실패율, p95와 p99 응답시간
- HPA 현재/목표 CPU, 현재/희망 replica 수
- 부하 시작부터 첫 scale-out까지 걸린 시간
- 최대 replica 수와 scale-in 완료 시간
- Pod별 요청 분산과 재시작 횟수

## 8. Self-Healing 실험

API에 지속적인 저강도 요청을 보내는 동안 `livescale-api` Pod 하나를 삭제한다. 다음 사건의 시각을 기록한다.

1. Pod 삭제 요청
2. 기존 Pod 종료
3. Replacement Pod 생성
4. Replacement Pod readiness 통과
5. Deployment replica 수 복구

성공 조건은 Deployment가 자동으로 두 replica를 회복하고, 실험 구간의 HTTP 실패율이 1% 미만인 것이다. VM 전원 차단이나 Worker 장애는 첫 구현 범위에 넣지 않고 Pod 장애 결과가 확보된 뒤 선택 실험으로 남긴다.

## 9. 테스트와 검증

애플리케이션은 pytest와 FastAPI TestClient로 다음 동작을 테스트 우선 방식으로 구현한다.

- 상태 확인 경로의 상태 코드와 응답
- 스트림 목록과 상세 응답 스키마
- 존재하지 않는 스트림의 `404`
- `/watch` 응답과 연산 함수의 결정성
- 환경 변수의 기본값과 유효성 검사

인프라는 다음 순서로 검증한다.

1. `terraform fmt -check`
2. `terraform validate`
3. 저장된 plan 검토 후 apply
4. Deployment rollout 완료 대기
5. 두 Worker에 Pod가 분산됐는지 확인
6. `/health`, `/streams`, `/watch` Ingress smoke test
7. Metrics API와 HPA target 값 확인
8. k6 임계값 평가
9. Pod 삭제 후 복구 시간과 요청 실패율 평가

검증 스크립트는 실패 시 0이 아닌 종료 코드를 반환하고 임시 Pod나 tar 파일을 정리한다.

## 10. 범위 제외

- 실제 치지직 내부 인프라에 대한 주장
- 영상 업로드, 송출, 트랜스코딩, CDN과 DRM
- 사용자 인증, 결제, 채팅과 알림
- 데이터베이스, Redis, Kafka와 영속 볼륨
- 다중 Control Plane 고가용성
- Worker 자동 증설과 클라우드 비용 최적화
- VMware Workstation VM 생명주기의 Terraform 관리
- 공개 레지스트리와 CI/CD 파이프라인

## 11. 완료 산출물

- 테스트를 통과하는 FastAPI 소스와 컨테이너 이미지
- 재실행 가능한 이미지 빌드·배포 스크립트
- Terraform 선언과 예제 변수 파일
- 실행 가능한 k6 시나리오
- HPA 및 Self-Healing 실험 결과 문서
- 설치, 배포, 검증, 제거 순서가 포함된 README

README 첫 부분에는 LiveScale이 실제 치지직 구현이 아니라 이벤트성 라이브 스트리밍 트래픽을 모티브로 한 학습 프로젝트임을 명시한다.
