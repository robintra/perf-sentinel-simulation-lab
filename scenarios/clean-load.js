// Clean baseline traffic for the ci-shift-left scenario.
//
// Exercises only OrderController endpoints (GET /api/orders, GET
// /api/orders/{id}). Deliberately avoids /api/fault/* endpoints so the
// resulting trace fixture is "clean" (no anti-patterns). The other 10 k6
// scripts in this directory each target one /api/fault/* endpoint and are
// used by `make validate-findings`.
//
// Override knobs : ORDER_URL (default localhost:8081 via port-forward),
// VUS (default 5), DURATION (default 30s).

import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  vus: __ENV.VUS ? parseInt(__ENV.VUS) : 5,
  duration: __ENV.DURATION || '30s',
};

const ORDER = __ENV.ORDER_URL || 'http://localhost:8081';

export default function () {
  let r = http.get(`${ORDER}/api/orders?limit=10`);
  check(r, { 'list 200': (res) => res.status === 200 });
  sleep(0.1);

  r = http.get(`${ORDER}/api/orders/1`);
  check(r, { 'get 200|404': (res) => res.status === 200 || res.status === 404 });
  sleep(0.2);
}
