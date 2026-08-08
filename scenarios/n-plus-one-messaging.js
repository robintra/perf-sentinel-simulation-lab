import http from 'k6/http';
import { sleep } from 'k6';

const ORDER = __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';

export const options = {
    vus: 5,
    duration: '30s',
    tags: { antiPattern: 'n_plus_one_messaging' },
};

export default function () {
    const r = http.post(`${ORDER}/api/fault/n-plus-one-messaging?messages=8`);
    if (r.status !== 200) {
        console.error(`n-plus-one-messaging failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
