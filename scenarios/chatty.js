import http from 'k6/http';
import { sleep } from 'k6';

const NOTIFICATION = __ENV.NOTIFICATION_SVC_URL || 'http://notification-service.shop.svc.cluster.local:8082';

export const options = {
    vus: 3,
    duration: '30s',
    tags: { antiPattern: 'chatty_service' },
};

export default function () {
    const r = http.post(`${NOTIFICATION}/api/fault/chatty?calls=30`);
    if (r.status !== 200) {
        console.error(`chatty failed: ${r.status} ${r.body}`);
    }
    sleep(0.5);
}
