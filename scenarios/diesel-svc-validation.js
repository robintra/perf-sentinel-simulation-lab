import http from 'k6/http';
import { sleep } from 'k6';

const STACK = 'diesel';
const PORT  = '8088';
const SERVICE = `${STACK}-svc`;
const BASE = __ENV.SERVICE_URL || `http://${SERVICE}.shop.svc.cluster.local:${PORT}`;

function post(path) {
    const r = http.post(`${BASE}${path}`);
    if (r.status !== 200) { console.error(`${path} on ${SERVICE} failed: ${r.status} ${r.body}`); }
    return r;
}

const DISPATCH = {
    n_plus_one_sql:    () => { post('/api/fault/n-plus-one-sql?items=15'); sleep(0.5); },
    n_plus_one_http:   () => { post('/api/fault/n-plus-one-http?recipients=10'); sleep(0.5); },
    redundant_sql:     () => { post('/api/fault/redundant-sql?repeats=10'); sleep(0.5); },
    redundant_http:    () => { post('/api/fault/redundant-http?repeats=10'); sleep(0.5); },
    slow_sql:          () => { post('/api/fault/slow-sql?delayMs=600&repeats=6'); sleep(1); },
    slow_http:         () => { post('/api/fault/slow-http?delayMs=600&repeats=6'); sleep(1); },
    excessive_fanout:  () => { post('/api/fault/fanout?width=40'); sleep(1); },
    chatty_service:    () => { post('/api/fault/chatty?calls=30'); sleep(1); },
    serialized_calls:  () => { post('/api/fault/serialized?steps=6'); sleep(1); },
    pool_saturation:   () => { post('/api/fault/pool-saturation?concurrency=20'); sleep(2); },
};

export default function() {
    const ap = __ENV.ANTI_PATTERN || 'n_plus_one_sql';
    const fn = DISPATCH[ap];
    if (!fn) { throw new Error(`unknown ANTI_PATTERN: ${ap}`); }
    fn();
}
