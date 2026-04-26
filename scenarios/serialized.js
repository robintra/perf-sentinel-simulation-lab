import http from 'k6/http';
import { sleep } from 'k6';

const NOTIFICATION = __ENV.NOTIFICATION_SVC_URL || 'http://notification-service.shop.svc.cluster.local:8082';

export const options = {
    vus: 3,
    duration: '30s',
    tags: { antiPattern: 'serialized_calls' },
};

export default function () {
    const r = http.post(`${NOTIFICATION}/api/fault/serialized?steps=6`);
    if (r.status !== 200) {
        console.error(`serialized failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
