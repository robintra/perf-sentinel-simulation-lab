import http from 'k6/http';
import { sleep } from 'k6';

const PAYMENT = __ENV.PAYMENT_SVC_URL || 'http://payment-service.shop.svc.cluster.local:8081';

export const options = {
    vus: 5,
    duration: '30s',
    tags: { antiPattern: 'redundant_sql' },
};

export default function () {
    const r = http.post(`${PAYMENT}/api/fault/redundant-sql?repeats=10`);
    if (r.status !== 200) {
        console.error(`redundant-sql failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
