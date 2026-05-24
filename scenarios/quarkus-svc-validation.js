// quarkus-svc multistack runner. The default function dispatches to
// the right anti-pattern via __ENV.ANTI_PATTERN, which the driver
// (scripts/run-multistack-scenario.sh) passes per sub-run with
// `--env ANTI_PATTERN=...`. vus/duration are CLI args.
//
// Why dispatch via env instead of `--exec`: k6 1.x CLI does not
// expose `--exec`, only env vars and `--scenario` (and the latter
// needs an `options.scenarios` block, which would force the composite
// 5-minute layout that conflicts with per-anti-pattern sub-runs).

import http from 'k6/http';
import { sleep } from 'k6';

const STACK = 'quarkus';
const PORT  = '8083';

const SERVICE = `${STACK}-svc`;
const BASE = __ENV.SERVICE_URL || `http://${SERVICE}.shop.svc.cluster.local:${PORT}`;

function post(path) {
    const r = http.post(`${BASE}${path}`);
    if (r.status !== 200) {
        console.error(`${path} on ${SERVICE} failed: ${r.status} ${r.body}`);
    }
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
    if (!fn) {
        throw new Error(`unknown ANTI_PATTERN: ${ap}`);
    }
    fn();
}
