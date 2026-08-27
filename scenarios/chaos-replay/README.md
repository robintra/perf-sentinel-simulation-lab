# chaos-replay

Validates that perf-sentinel **degrades cleanly on the telemetry of a system
that is genuinely failing**: the OpenTelemetry Astronomy Shop demo driven
through a scripted chaos window - flagd failure flags plus container-level
kill/pause - captured once, then replayed forever from a committed slice.

This is the last of the four "break the assumptions" axes (clean /
complete / mono-convention / **coherent** telemetry). The first three are
covered by the upstream fuzzing suite, `sampling-degradation` and
`semconv-drift`. Those are offline transforms of healthy captures. This
corpus is different in kind - it is what real instrumentation actually
emits while the system breaks:

- **real ERROR spans** - payment unreachable, Kafka queue problems;
- **structural half-traces** - `checkout` (a mid-tier orchestrator) is
  SIGKILLed mid-load: its buffered spans die with it while its callees
  (payment, shipping, currency, ...) still export SERVER spans whose
  `parentSpanId` points at spans that never arrived. A leaf-service kill
  cannot produce this shape;
- **client timeouts** - `shipping` paused (SIGSTOP) for 90 s, then resumed:
  calls hang until deadline, the paused service's own spans complete with
  huge durations after the unpause;
- **flood traffic** - `loadGeneratorFloodHomepage` while all of the above
  happens.

## What it asserts

| id | assertion |
|----|-----------|
| X1 | `analyze --input chaos-slice.ndjson`: exit 0, `traces_analyzed` equals the stamped value, no panic on stderr - clean degradation, not survival by luck |
| X2 | per-class finding census equals the stamped census: deterministic replay, so any drift (a count change OR an invented finding class) forces a human look; restamping is a deliberate act (rerun capture.sh) |
| X3 | chaos guard: the slice still contains the stamped counts of ERROR spans and broken-parent traces - proves the committed corpus is actually chaotic, so X1/X2 can never pass vacuously on a tame slice |
| X4 | `report --input chaos-slice.ndjson` renders a usable dashboard |

## Restamp history

The census is only meaningful next to the binary that produced it, so every
restamp is recorded here.

**0.15.0.** The stamp had been carried since 0.11.0 and the gate was red from
0.12.0 on, unnoticed because the lab gate was paused between 0.13.0 and 0.15.0.
Replaying the unchanged slice on the published 0.11.0, 0.12.0, 0.13.0, 0.13.1
and 0.14.0 images puts the change squarely in 0.12.0, and 0.15.0 reproduces
0.12.0 exactly:

| | 0.11.0 (old stamp) | 0.12.0 onwards |
|---|---|---|
| `traces_analyzed` | 249 | 241 |
| `redundant_http` | 279 | 57 |
| `n_plus_one_http` | 5 | 3 |
| `chatty_service` | 32 | 31 |
| `slow_http` | 2 | absent |

Every finding that disappeared is an HTTP one, and every disappearing key is a
SERVER-span artefact: 70 distinct `redundant_http` identities collapse to 5,
and the largest were `frontend-proxy` rows carrying `source_endpoint:
"unknown"` and templates like `GET frontend-proxy/`. A proxy receiving N
requests was being read as a service making N redundant outbound calls. 0.12.0
stopped counting inbound SERVER spans as outbound work, which is why
`traces_analyzed` drops too: a trace made only of proxy SERVER spans has
nothing left to analyze. The drop is a false-positive reduction, so the new
census is the correct one.

Bisecting the 0.11.0..0.12.0 range pins it to a single commit,
`f01669ad fix(ingest): exclude server spans from http out`: its parent
reproduces the old census exactly and it reproduces the new one exactly, which
rules out the neighbouring endpoint-resolution fixes in the same batch.

Worth knowing: the change shipped undocumented. The CHANGELOG entry under
`[0.12.0]` was written retroactively, from this gate. `redundant_sql`,
`serialized_calls` and `excessive_fanout` are identical across all six
binaries, which is what rules out the documented 0.12.0 session-command fixes
as the cause.

## How it works

Capture once, replay forever - the demo shares the pinned clone in
`artifacts/astronomy-shop/otel-demo` with the astronomy-shop scenario and is
never deployed into the lab k3d cluster:

- `capture.sh` (one-off) reuses the astronomy-shop machinery (same tag pin,
  same `otelcol-config-extras.yml` file-exporter injection, same stop/mv/start
  dump rotation rule) but runs a single **chaos window** instead of
  clean/degraded phases. The choreography is driven by the manifest:
  1. enable `chaos.flags_enabled` (`paymentUnreachable`,
     `kafkaQueueProblems`, `adHighCpu`, `loadGeneratorFloodHomepage`), then
     rotate the dump so the window is 100% flagged traffic;
  2. at `chaos.kill.at_offset_s`, `docker compose kill` the kill service,
     restart it `down_s` later;
  3. at `chaos.pause.at_offset_s`, `docker compose pause` the pause service,
     unpause `pause_s` later;
  4. at `chaos.window_minutes`, stop the collector and take the dump.
- The dump is curated with `../astronomy-shop/curate.py` (the eligibility
  filter is purely **temporal** - trace extents inside the window minus
  an edge guard - so the structural half-traces survive curation. That is
  the point of the corpus).
- capture.sh refuses to stamp a tame corpus: zero ERROR spans or zero
  broken-parent traces in the curated slice is a hard error with a tuning
  hint, not a stampable outcome.
- `fixtures/fixture-manifest.json` is the contract: the `chaos` block and
  `traces` drive the capture. `demo_version`, `otel_demo_commit`,
  `traces_analyzed`, `finding_census`, `error_spans` and
  `broken_parent_traces` are stamped back as **exact observed values**
  (deterministic committed input + deterministic binary, no slack), and
  verify.sh re-derives all of them.

## Run

```sh
make verify-chaos-replay      # replay the committed slice (no cluster, no Docker)
make capture-chaos-replay     # one-off: rerun the chaos window and restamp
```

Replay requires only the local release binary (`cargo build --release` in the
perf-sentinel checkout), python3 and jq. Capture additionally needs Docker
(~8 GiB for the demo, ~20 min end to end), docker compose v2, git and curl -
and free ports 8080/10000. Report: `/tmp/scenario-chaos-replay-report.md`.
