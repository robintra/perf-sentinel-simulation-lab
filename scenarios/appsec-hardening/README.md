# appsec-hardening

Validates the perf-sentinel 0.9.15 AppSec remediation behaviours end to end,
self-contained (local release binary only, no cluster, no docker).

## What it checks

| leg | behaviour (new in 0.9.15) | 0.9.14 behaviour |
|---|---|---|
| A | `analyze` strips query string, fragment and userinfo from `source_endpoint` (and the ack signature) when the endpoint comes from a raw URL; `@` inside a path and route templates survive | leaks `user:pass@shop-svc/api/orders?token=SECRET#frag` verbatim into endpoint + signature |
| B | `GET /api/acks` returns 401 without `X-API-Key` when a key is configured, `PERF_SENTINEL_ACK_API_KEY` overrides the TOML key (both go through the same >=12-char validation). `[daemon] read_api_key` (0.20.0) answers 200 on `GET /api/acks` and 401 on `POST /api/findings/{sig}/ack` | GET served without any key (writes already gated), no read key |
| C | `/api/export/report` evaluates the real quality gate: 3 rules always present, a critical N+1 SQL with `n_plus_one_sql_critical_max = 0` flips `passed:false` | hardcoded `passed:true, rules:[]` |
| D | a report carrying `integrity.binary_attestation` caps at PARTIAL (exit 2) with a `--verify-binary <path>` hint; the injection happens post-`hash-bake` and the content hash still validates (post-sign field) | no `--verify-binary` flag; hint says to run `gh attestation verify` manually |
| E | non-loopback bind (`0.0.0.0`) logs the advisory but the daemon serves; the widening itself is pinned by a second bind on `[::1]`, silent on 0.9.15 | `0.0.0.0` also warned, but `[::1]` warned too (only the literal spellings `127.0.0.1`/`::1` were recognized) |

## Version discrimination (checked once against ghcr 0.9.14, 2026-07-23)

Run against the 0.9.14 GHCR image, the legs fail exactly as expected. Leg
A leaks the full URL, leg B answers 200 on the bare GET, and leg C returns
`rules: []` on the cold envelope. Leg D lacks the `--verify-binary` flag
and its hint text differs. Leg E's `[::1]` bind draws the advisory,
because the 0.9.14 matcher only recognized the literal spellings. The
PARTIAL exit code itself is not a discriminator on an unsigned report
(both versions cap at 2). Leg D therefore asserts the new hint text and
flag, which are 0.9.15-only.

## Prerequisites

- Local release binary at `$PERF_SENTINEL_REPO_PATH/target/release/perf-sentinel`
  built from `feature/0.20.0` or later (`cargo build --release -p perf-sentinel`),
  leg B needs the `[daemon] read_api_key` gate.
- `jq`, `python3`. Ports 14406-14407 free on loopback. Leg E additionally
  binds 14408-14409 on **all interfaces** (`0.0.0.0`, that is the point of
  the advisory leg, so expect a firewall prompt on first run) and then on
  `[::1]`.

## Run

```bash
make verify-appsec-hardening
# or
./scenarios/appsec-hardening/verify.sh
```

Report: `/tmp/scenario-appsec-hardening-report.md`.

## Fixture

`fixtures/appsec.native.json` is a synthetic native SpanEvent capture,
three traces on `appsec-svc`: 12 SQL spans behind
`http://user:pass@shop-svc/api/orders?token=SECRET#frag` (critical N+1,
the redaction target), 6 behind `/users/a@b.example/orders` (path-`@`
control), 6 behind `GET /api/orders/{id}` (route-template control).
