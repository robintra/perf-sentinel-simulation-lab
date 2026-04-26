import http from 'k6/http';
import { sleep } from 'k6';

const NOTIFICATION = __ENV.NOTIFICATION_SVC_URL || 'http://notification-service.shop.svc.cluster.local:8082';

export const options = {
    vus: 5,
    duration: '30s',
    tags: { antiPattern: 'n_plus_one_http' },
};

export default function () {
    const r = http.post(`${NOTIFICATION}/api/fault/n-plus-one-http?recipients=10`);
    if (r.status !== 200) {
        console.error(`n-plus-one-http failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
