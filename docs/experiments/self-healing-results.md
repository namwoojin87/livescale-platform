# Pod Self-Healing 실험 결과

## 실험 개요

- 실행 시각: 2026-08-25 16:24 KST
- 부하: 3 VU, 60초
- 대상: `http://172.16.8.50/streams/1/watch`
- 초기/목표 replica: 2개
- 복구 제한 시간: 120초

HPA 확장 실험과 섞이지 않도록 CPU 목표 60% 아래에 머무는 3 VU를 사용했다. k6가 지속적으로 Ingress 요청을 보내기 시작한 약 10초 뒤 Ready Pod 하나를 이름으로 지정해 삭제했다.

## 삭제 및 복구 사건

| 사건 | Pod | UID | 노드 | 경과 시간 |
|---|---|---|---|---:|
| 삭제 요청 | `livescale-api-766d9d6c74-9lpd2` | `bf612736-9705-431d-ae19-f7eb3fd4e6c4` | `livescale-worker-2` | 0초 |
| Replacement 관찰 | `livescale-api-766d9d6c74-j2mml` | `c49d5082-0553-4d92-abe1-a8fc5fc389c0` | `livescale-worker-2` | 2.234초 |
| Readiness 및 replica 복구 | `livescale-api-766d9d6c74-j2mml` | 동일 | `livescale-worker-2` | 9.404초 |

새 Pod는 기존 두 UID에 포함되지 않는 UID로 확인했다. 복구 완료 시 Deployment는 `2/2 Available` 상태였다.

## 요청 연속성

| 지표 | 결과 | 임계값 |
|---|---:|---:|
| 총 요청 | 862 | - |
| HTTP 실패율 | 0.00% | 1% 미만 |
| Check 성공률 | 100.00% | 99% 초과 |
| 평균 응답시간 | 8.37ms | - |
| p95 응답시간 | 13.32ms | 500ms 미만 |
| p99 응답시간 | 15.20ms | - |
| 최대 응답시간 | 16.64ms | - |

Pod 삭제 및 교체 구간을 포함해 HTTP 실패는 한 건도 발생하지 않았다.

## 최종 상태

```text
Deployment: 2/2 Ready, 2 Available
HPA: cpu 42%/60%, replicas 2
livescale-worker-1: 1 Pod Ready
livescale-worker-2: 1 replacement Pod Ready
Docker service/socket: inactive
```

## 재현 명령

낮은 부하를 실행한다.

```bash
docker run --rm --network host \
  -v /tmp/livescale-k6:/scripts:ro \
  grafana/k6:2.1.0 run --quiet --vus 3 --duration 60s /scripts/spike.js
```

트래픽 시작 후 별도 PowerShell에서 다음을 실행한다.

```powershell
./scripts/experiments/delete-pod.ps1 `
  -Kubeconfig work/kubeconfig-livescale.yaml `
  -TimeoutSeconds 120
```

로컬 원본 결과는 `work/results/self-healing.json`에 저장되며 Git에는 포함하지 않는다.
