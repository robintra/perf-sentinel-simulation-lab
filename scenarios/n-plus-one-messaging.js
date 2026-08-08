import http from 'k6/http';
import { check } from 'k6';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 5,
    duration: '30s',
    tags: { antiPattern: 'n_plus_one_messaging' },
    thresholds: { checks: ['rate==1'] },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/n-plus-one-messaging?messages=8`);
    let body = {};
    try {
        body = r.json();
    } catch (_) {
        // The check below reports malformed error responses.
    }
    const ok = check(r, {
        'publishes and confirms all requested messages': (res) =>
            res.status === 200 && body.antiPattern === 'n_plus_one_messaging' &&
            body.details && body.details.published === 8 && body.details.confirmed === 8,
    });
    if (!ok) {
        console.error(`n-plus-one-messaging failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
