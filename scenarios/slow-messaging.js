import http from 'k6/http';
import { check } from 'k6';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 1,
    duration: '15s',
    tags: { antiPattern: 'slow_messaging' },
    thresholds: { checks: ['rate==1'] },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/slow-messaging?delayMs=600&repeats=3`);
    let body = {};
    try {
        body = r.json();
    } catch (_) {
        // The check below reports malformed error responses.
    }
    const ok = check(r, {
        'publishes and confirms all requested messages': (res) =>
            res.status === 200 && body.antiPattern === 'slow_messaging' &&
            body.details && body.details.published === 3 && body.details.confirmed === 3 &&
            body.details.delay_ms === 600,
    });
    if (!ok) {
        console.error(`slow-messaging failed: ${r.status} ${r.body}`);
    }
    sleep(1);
}
