// go-svc multistack runner. Same dispatcher pattern as the other
// multistack scenarios. Driven by scripts/run-multistack-scenario.sh
// via __ENV.ANTI_PATTERN.

import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const STACK = 'go';
const PORT  = '8093';

const SERVICE = `${STACK}-svc`;
const BASE = __ENV.SERVICE_URL || `http://${SERVICE}.shop.svc.cluster.local:${PORT}`;

export const options = {
    thresholds: { checks: ['rate==1'] },
};

function postChecked(path, requested = null) {
    const r = http.post(`${BASE}${path}`);
    let body = null;
    try { body = r.json(); } catch (_) { /* checked below */ }
    const valid = check(r, {
        'HTTP 200': (response) => response.status === 200,
        'JSON object': () => body !== null && typeof body === 'object',
        'messaging confirms requested count': () => requested === null || (
            body.details && body.details.published === requested &&
            body.details.confirmed === requested),
    });
    if (!valid) fail(`${path}: status=${r.status} body=${r.body}`);
    return body;
}

const DISPATCH = {
    n_plus_one_sql:    () => { postChecked('/api/fault/n-plus-one-sql?items=15'); sleep(0.5); },
    n_plus_one_http:   () => { postChecked('/api/fault/n-plus-one-http?recipients=10'); sleep(0.5); },
    redundant_sql:     () => { postChecked('/api/fault/redundant-sql?repeats=10'); sleep(0.5); },
    redundant_http:    () => { postChecked('/api/fault/redundant-http?repeats=10'); sleep(0.5); },
    slow_sql:          () => { postChecked('/api/fault/slow-sql?delayMs=600&repeats=6'); sleep(1); },
    slow_http:         () => { postChecked('/api/fault/slow-http?delayMs=600&repeats=6'); sleep(1); },
    excessive_fanout:  () => { postChecked('/api/fault/fanout?width=40'); sleep(1); },
    chatty_service:    () => { postChecked('/api/fault/chatty?calls=30'); sleep(1); },
    serialized_calls:  () => { postChecked('/api/fault/serialized?steps=6'); sleep(1); },
    pool_saturation:   () => { postChecked('/api/fault/pool-saturation?concurrency=20'); sleep(2); },
    n_plus_one_messaging: () => { postChecked('/api/fault/n-plus-one-messaging?messages=8&broker=rabbitmq', 8); sleep(0.5); },
    slow_messaging: () => { postChecked('/api/fault/slow-messaging?delayMs=600&repeats=3&broker=rabbitmq', 3); sleep(1); },
};

export default function() {
    const ap = __ENV.ANTI_PATTERN || 'n_plus_one_sql';
    const fn = DISPATCH[ap];
    if (!fn) {
        throw new Error(`unknown ANTI_PATTERN: ${ap}`);
    }
    fn();
}
