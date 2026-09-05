# incident-window-capture

What was already burning on a service in the minutes before it was
OOM-killed, and the capture that answers it before the ring forgets.

## Why it exists

perf-sentinel cannot see the memory of an observed service and cannot detect a
crash. There is no OTLP metrics path, so `process.runtime.jvm.memory.used` and
`container_memory_working_set_bytes` never arrive. `SpanEvent` carries no
status, the OTLP `Span.status` and the `exception.*` events are read nowhere,
and there is no per-service heartbeat. Worse, a service saturating its heap
usually keeps emitting spans, more slowly, so no heuristic over the traces
rescues the case.

What perf-sentinel does own is the findings of a period, and it is the only
thing that can freeze them before they disappear. The findings ring is a FIFO
of 10 000 with no TTL. On a loaded fleet it turns over in minutes, so by the
time anyone opens a terminal the window of the incident has already been
evicted.

Hence the split this scenario validates: **the moment comes from outside, the
window comes from perf-sentinel, and the capture has to be immediate.** The
operator's alerting already knows when a pod restarts or saturates, that is
its job. perf-sentinel answers instantly and does not let the answer
evaporate.

`make verify-incident-window-capture`. Self-contained: a local release binary,
python3 and curl. No cluster, no Docker. Around 15 seconds.

## What it asserts

**1. Counters pre-warmed, archive opened at startup.** The four reasons of
`perf_sentinel_incidents_rejected_total` and the five kinds of
`perf_sentinel_incidents_total` are present at zero before anything happens: a
series that materialises only once it fires cannot be alerted on. The NDJSON
archive exists with mode 0600 before the first incident, because a read-only
filesystem or a typo has to fail the daemon, not the first delivery.
`/api/config` reports `read_api_key_set` and `incidents_enabled` true, without
the keys themselves.

**A, the freeze at reception.** A `firing` Alertmanager envelope is accepted
and the findings of `[at_ms - lookback_ms, at_ms + 2 * trace_ttl_ms]` are
captured on the spot. The window closes *after* the incident on purpose: a
finding is stamped when its trace is analysed, one TTL after its last span, so
the traces live at the crash land past `startsAt` and a window closed at the
stamp would miss exactly what a post-mortem wants. The service label is padded
with spaces in the delivery and trimmed in the record, because a quoted YAML
value keeps its space and the service is the join key to the findings.
`oldest_finding_ms` sits above `window_from_ms`, which is what says the
capture is complete rather than eaten into by eviction.

**B, the settle pass grows the record.** A second anti-pattern is seeded right
after the delivery, so it is analysed after the reception freeze but inside
the window. One TTL past the window's close, the settle re-resolves the same
window and merges by signature. The assertion is not that the row count moved,
it is that the row captured at reception is still there next to the new one: a
settle that replaced the capture would also read as two rows on a lucky day.

**C, idempotence and what counts as an end.** A repost answers `repeated: 1`
with `recorded: 0` and leaves the settled rows alone. An `endsAt` before
`startsAt`, which a clock-skewed resolve produces, is not an end and does not
seal the record against the corrected delivery that follows.

**D, every refusal counted.** `POST` and `GET` both answer 401 without the key
and both are counted. `[daemon] read_api_key`, a second key that differs from
the write key, opens `GET /api/incidents` (200) and never the `POST` (401), and
that refusal is counted too, so `unauthorized` reads 3. A delivery of 1001
alerts without the service label lands `no_service = 1000` and `overflow = 1`,
an unparsable `startsAt` lands `unparsable_time = 1`. The intake body says the
same thing, but Alertmanager discards it and never retries a 4xx, so a receiver
with the wrong header or a rule with the wrong label loses every capture with
nothing else moving.

**E, durability.** The ring dies with the daemon, and a node-level memory event
that kills the observed service often takes a co-located daemon with it,
destroying the record that would explain the outage. The archive holds one
intact line per record, all under one content-derived id, the last carrying
the end, written by a single task so two records can never interleave. A
symlinked `archive_path` refuses startup.

**F, the window form of the listing.** `GET /api/findings` with `since_ms` and
`until_ms` folds over the detections inside the window alone, so a window
closed at the incident holds fewer rows than the whole buffer. An upper bound
applied after the fold would instead keep every group whose lifetime overlaps
the window, and a chronic pattern running all week would match every incident
window ever asked for. `/api/status` reports `oldest_finding_ms`, which
separates "nothing fired" from "the ring no longer reaches that far back",
two answers that were the same empty response before 0.20.0.

**G, the last-span gauge.** `perf_sentinel_service_last_span_timestamp_seconds`
is a Unix stamp, not an age, on the convention of `process_start_time_seconds`,
so `time() - gauge` gives the age. It adds two things over
`increase(perf_sentinel_service_io_ops_total[10m]) == 0`, which already answers
"perf-sentinel no longer hears this service": an age not bounded by the range
vector's window, and *absence* rather than zero after a daemon restart, where
every counter resets and a whole fleet looks stopped.

## What it does not assert

The gauge is a traffic signal, not a liveness signal. A crash, a scale to zero,
a deploy, a load balancer drain and a quiet cron all read the same, and
`apply_sampling` runs before the meters, so a low-throughput service under
`sampling_rate < 1.0` can read old while healthy. Any alert on it needs a `for:`
longer than the service's normal idle time, plus an `absent_over_time` if the
daemon's own death matters.

The settle is one pass, not a poll. A finding analysed after the settle fired
never reaches the record, and a daemon restarted between the delivery and the
settle loses the pass with the ring. That is the trade the archive covers: the
reception capture is already on disk.
