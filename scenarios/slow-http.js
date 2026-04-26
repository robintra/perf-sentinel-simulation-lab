import http from 'k6/http';
import { sleep } from 'k6';

const PAYMENT = __ENV.PAYMENT_SVC_URL || 'http://payment-service.shop.svc.cluster.local:8081';

export const options = {
    vus: 3,
    duration: '30s',
    tags: { antiPattern: 'slow_http' },
};

export default function () {
    const r = http.post(`${PAYMENT}/api/fault/slow-http?delayMs=600&repeats=6`);
    if (r.status !== 200) {
        console.error(`slow-http failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
