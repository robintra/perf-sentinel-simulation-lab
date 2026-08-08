import http from 'k6/http';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 1,
    duration: '15s',
    tags: { antiPattern: 'slow_messaging' },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/slow-messaging?delayMs=600&repeats=3`);
    if (r.status !== 200) {
        console.error(`slow-messaging failed: ${r.status} ${r.body}`);
    }
    sleep(1);
}
