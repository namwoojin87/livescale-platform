# HPA 이벤트성 트래픽 실험 결과

## 실험 개요

- 실행 시각: 2026-08-25 16:13 KST
- k6 버전: `2.1.0`
- 대상: `http://172.16.8.50/streams/1/watch`
- Ingress Host: `livescale.local`
- 초기 Pod: 2개
- HPA: 최소 2개, 최대 8개, CPU 목표 60%
- API CPU 연산: 요청당 SHA-256 5,000회
- 관찰 주기: 약 5초

트래픽 단계는 30초 동안 5 VU, 60초 동안 10 VU, 60초 동안 100 VU까지 증가, 180초 동안 100 VU 유지, 60초 동안 0 VU로 감소하는 순서로 실행했다.

## k6 결과

| 지표 | 결과 | 임계값 |
|---|---:|---:|
| 총 요청 | 115,904 | - |
| 평균 처리량 | 297.10 req/s | - |
| HTTP 실패율 | 0.00% | 1% 미만 |
| Check 성공률 | 100.00% | 99% 초과 |
| 평균 응답시간 | 13.02ms | - |
| p95 응답시간 | 21.18ms | 500ms 미만 |
| p99 응답시간 | 31.52ms | - |
| 최대 응답시간 | 399.59ms | - |

모든 k6 임계값을 통과했다.

## HPA 반응

| 사건 | 테스트 시작 후 시간 | 상태 |
|---|---:|---|
| 관찰 시작 | 0초 | 2 replicas, CPU 4% |
| 첫 Scale-out | 54.7초 | 2 → 3 replicas |
| 추가 Scale-out | 약 87초 | 3 → 5 replicas |
| 최대 replica 도달 | 132.5초 | 8 replicas |
| 관찰된 최대 평균 CPU | - | requests 대비 400% |
| Scale-in 완료 | 479.6초 | 8 → 3 → 2 replicas |

k6 실행은 약 390초에 종료됐고 HPA는 약 90초 후 2개로 돌아왔다. 이는 60초 scale-down 안정화 시간과 Metrics 수집 지연이 함께 반영된 결과다. 최대 부하 구간에서도 8개 Pod가 모두 Ready 상태를 유지했다.

최종 상태는 다음과 같다.

```text
cpu: 3%/60%
replicas: 2
livescale-worker-1: 1 Pod Ready
livescale-worker-2: 1 Pod Ready
```

## 재현 명령

Control Plane에서 Docker를 실행한 상태로 다음 컨테이너를 사용한다.

```bash
docker run --rm --network host \
  -v /tmp/livescale-k6:/scripts:ro \
  grafana/k6:2.1.0 run --quiet /scripts/spike.js
```

동시에 Windows 호스트에서 다음 관찰기를 실행한다.

```powershell
./scripts/experiments/observe-hpa.ps1 `
  -Kubeconfig work/kubeconfig-livescale.yaml `
  -DurationSeconds 480 `
  -IntervalSeconds 5
```

원본 관찰 CSV는 자격 증명과 무관하지만 실행 시각별 로컬 결과이므로 `work/results/hpa-observations.csv`에 보관하고 Git에는 포함하지 않는다.
