import http from 'k6/http';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 5,
    duration: '30s',
    tags: { antiPattern: 'redundant_http' },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/redundant-http?repeats=10`);
    if (r.status !== 200) {
        console.error(`redundant-http failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
