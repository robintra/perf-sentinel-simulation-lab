import http from 'k6/http';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 3,
    duration: '30s',
    tags: { antiPattern: 'slow_sql' },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/slow-sql?delayMs=600&repeats=6`);
    if (r.status !== 200) {
        console.error(`slow-sql failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
