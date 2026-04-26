import http from 'k6/http';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 2,
    duration: '30s',
    tags: { antiPattern: 'pool_saturation' },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/pool-saturation?concurrency=20`, null, {
        timeout: '60s',
    });
    if (r.status !== 200) {
        console.error(`pool-saturation failed: ${r.status} ${r.body}`);
    }
    sleep(2);
}
