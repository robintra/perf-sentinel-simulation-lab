// _multistack-template.js — composite k6 scenario template for the
// multistack lab expansion.
//
// Each multistack service (Quarkus, Helidon SE/MP, .NET, Rust+Diesel,
// Rust+SeaORM, NestJS, Django, FastAPI, Go) ships its own composite
// scenario at scenarios/<stack>-svc-validation.js, derived from THIS
// template. The composite scenario fires all 10 fault endpoints of the
// target service in a single k6 run (one VU group per anti-pattern),
// so a single `k6 run` invocation produces traces for every anti-pattern
// the service is contracted to reproduce.
//
// After the run completes, drive scripts/validate-findings-multistack.sh
// <stack>-svc to grade the daemon findings against the 10 expected
// anti-pattern types tagged with `service = <stack>-svc`.
//
// To derive a per-stack scenario from this template:
//   1. Copy this file to scenarios/<stack>-svc-validation.js.
//   2. Edit the STACK constant (e.g. 'quarkus').
//   3. Edit the PORT constant to match the service-port mapping in
//      docs/MULTISTACK.md (e.g. 8083 for quarkus-svc).
//   4. Keep everything else identical — the 10 fault endpoints follow
//      the same /api/fault/<name> contract for every stack.
//
// Verify the contract first via docs/MULTISTACK.md if anything is
// unclear.

import http from 'k6/http';
import { sleep } from 'k6';

// === per-stack customisation ===========================================
const STACK = __ENV.STACK || 'EDIT_ME';   // e.g. 'quarkus', 'helidon-se'
const PORT  = __ENV.PORT  || '8083';      // see docs/MULTISTACK.md
// =======================================================================

const SERVICE = `${STACK}-svc`;
const BASE = __ENV.SERVICE_URL || `http://${SERVICE}.shop.svc.cluster.local:${PORT}`;

// Per-anti-pattern VU/duration tuning mirrors the Java baseline
// scenarios. The scenarios stanza runs them sequentially via the
// `startTime` offsets so the daemon sees a clean isolation between
// anti-pattern bursts (helps cross-trace correlation grouping). Total
// wall-clock is about 5 minutes per stack.
export const options = {
    scenarios: {
        n_plus_one_sql: {
            executor: 'constant-vus', vus: 5, duration: '30s',
            startTime: '0s',  exec: 'nPlusOneSql',
            tags: { antiPattern: 'n_plus_one_sql' },
        },
        n_plus_one_http: {
            executor: 'constant-vus', vus: 5, duration: '30s',
            startTime: '30s', exec: 'nPlusOneHttp',
            tags: { antiPattern: 'n_plus_one_http' },
        },
        redundant_sql: {
            executor: 'constant-vus', vus: 5, duration: '30s',
            startTime: '60s', exec: 'redundantSql',
            tags: { antiPattern: 'redundant_sql' },
        },
        redundant_http: {
            executor: 'constant-vus', vus: 5, duration: '30s',
            startTime: '90s', exec: 'redundantHttp',
            tags: { antiPattern: 'redundant_http' },
        },
        slow_sql: {
            executor: 'constant-vus', vus: 3, duration: '30s',
            startTime: '120s', exec: 'slowSql',
            tags: { antiPattern: 'slow_sql' },
        },
        slow_http: {
            executor: 'constant-vus', vus: 3, duration: '30s',
            startTime: '150s', exec: 'slowHttp',
            tags: { antiPattern: 'slow_http' },
        },
        fanout: {
            executor: 'constant-vus', vus: 3, duration: '30s',
            startTime: '180s', exec: 'fanout',
            tags: { antiPattern: 'excessive_fanout' },
        },
        chatty: {
            executor: 'constant-vus', vus: 3, duration: '30s',
            startTime: '210s', exec: 'chatty',
            tags: { antiPattern: 'chatty_service' },
        },
        serialized: {
            executor: 'constant-vus', vus: 3, duration: '30s',
            startTime: '240s', exec: 'serialized',
            tags: { antiPattern: 'serialized_calls' },
        },
        pool_saturation: {
            executor: 'constant-vus', vus: 2, duration: '30s',
            startTime: '270s', exec: 'poolSaturation',
            tags: { antiPattern: 'pool_saturation' },
        },
    },
};

function post(path) {
    const r = http.post(`${BASE}${path}`);
    if (r.status !== 200) {
        console.error(`${path} on ${SERVICE} failed: ${r.status} ${r.body}`);
    }
    return r;
}

export function nPlusOneSql()    { post('/api/fault/n-plus-one-sql?items=15'); sleep(0.5); }
export function nPlusOneHttp()   { post('/api/fault/n-plus-one-http?recipients=10'); sleep(0.5); }
export function redundantSql()   { post('/api/fault/redundant-sql?repeats=10'); sleep(0.5); }
export function redundantHttp()  { post('/api/fault/redundant-http?repeats=10'); sleep(0.5); }
export function slowSql()        { post('/api/fault/slow-sql?delayMs=600&repeats=6'); sleep(1); }
export function slowHttp()       { post('/api/fault/slow-http?delayMs=600&repeats=6'); sleep(1); }
export function fanout()         { post('/api/fault/fanout?width=40'); sleep(1); }
export function chatty()         { post('/api/fault/chatty?calls=30'); sleep(1); }
export function serialized()     { post('/api/fault/serialized?steps=6'); sleep(1); }
export function poolSaturation() { post('/api/fault/pool-saturation?concurrency=20'); sleep(2); }
