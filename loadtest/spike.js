import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.BASE_URL || 'http://172.16.8.50';

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
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

export default function () {
  const response = http.get(`${baseUrl}/streams/1/watch`, {
    headers: { Host: 'livescale.local' },
    tags: { endpoint: 'watch' },
  });

  check(response, {
    'watch returns 200': (res) => res.status === 200,
    'watch response is served by a pod': (res) => {
      try {
        return Boolean(res.json('served_by'));
      } catch (_) {
        return false;
      }
    },
  });
  sleep(0.2);
}
