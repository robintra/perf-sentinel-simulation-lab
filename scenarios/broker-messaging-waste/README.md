# broker-messaging-waste

Gates the two coupled blocks added on top of 0.9.22: **OTel messaging
ingestion** and **broker energy attribution**.

Broker spans (Kafka, RabbitMQ, Pulsar, SQS, NATS, JMS) used to be dropped as
`not_io`, so an architecture built on a bus read as analysed while half of its
business path was mute. They become `EventType::Messaging` with two finding
types (`n_plus_one_messaging`, `slow_messaging`) and a producer → consumer edge
resolved through OTel span links.

Deterministic batch fixtures now assert both `n_plus_one_messaging` and
`slow_messaging` through executable code.

No joules-per-message coefficient is derivable — broker power stops tracking
throughput past roughly 20% of capacity — so the **broker's** energy is measured
and split by a ratio the traces can produce, exactly like `database_waste`. Two
sources: `[green.alumet.broker]` (cgroup measurement) and
`[green.broker_static]` (a declared provisioned cluster, the only option on a
managed broker). Measurement wins over declaration.

## Why the lab and not a unit test

The product ships 2333 green tests, and the two-source arbitration is covered
there against an **injected clock**: `take_broker_energy` and
`patch_broker_energy` receive `now` as a parameter, so the six switchover cases
are deterministic and already green in CI.

That is precisely the limit. Those tests never meet a scraper that

- delivers its energy **per scrape interval and retroactively**,
- can answer **without carrying the expected label**, and
- can **die and come back**.

This scenario is the only place the three coexist. The arbitration was rewritten
three times in review, each correction revealing the next, and then twice more
during this validation — legs A1–A7 map onto the rules the current code rests on,
and A7 exists because a fix to A4's path reopened it once already.

## What it asserts

| leg | assertion |
|-----|-----------|
| D  | eight configuration cases: half-declared `[green.broker_static]` (`nodes` without `instance_type`), `provider = "asw"`, the broker cgroup colliding with `service_mappings`, the same cgroup declared as both broker and database, `[green.alumet.broker]` without an `[green.alumet]` endpoint, an invalid broker `region`, and a control char in the broker `label_value` — all refused at load, each naming **that** section and never `[green.alumet.database]`; plus `provider = ""` **accepted** and resolved to `generic` |
| A1 | nominal regime, Alumet live and labelled: `messaging_waste.model` is `alumet_rapl` in every window once the measurement owns the timeline, and `broker_specpower` bills none of them |
| A2 | the energy summed over the run is the cgroup's own (closed form: `elapsed × J / (energy_interval × 3.6e6)`), not the declared cluster's. A per-tick double billing — the arbitration's first failure mode — lands near 2× and cannot hide in the band |
| A3 | Alumet cut: falls back to `broker_specpower` once past the staleness window (3× the scrape interval), leaving no window without a figure |
| A4 | Alumet back, handing over the whole outage in one catch-up reading: that retroactive delta covers wall clock the declaration already billed and must be dropped exactly once |
| A5 | healthy endpoint, `label_value` absent from the exposition: `broker_specpower` continuously and `messaging_waste` **present**. This is the review regression — an endpoint that answers without the label measures nothing and must not suppress the fallback |
| A6 | daemon booted with Alumet unreachable: the declaration bills from the first windows. A state never scraped must not read "fresh" while it waits out its first staleness window |
| B  | disclosure v1.5: `aggregate.messaging_waste` with its three provenance buckets and the invariant `measured + declared + estimated == windows_with_figure`; a `broker_static`-only period giving `measured_windows = 0` (a shape no unit test exercised); the **v1.4 disclosure written by 0.9.22** still verifying under this binary; and no messaging block or `declared_*` field invented on a bus-free period |
| A7 | a late scrape banks a delta covering a hole the declaration already billed, with **no scoring window running while that sample is fresh** (quiet traffic, or shed batches). The path A4 cannot reach: there, a window scores while the sample is fresh, so the measurement legitimately owns it |
| C  | `Broker waste` on `/api/export/report`, in `query monitor`'s Energy tab and in the HTML dashboard, with no flicker across windows |
| E  | destination spellings the lab has no emitter for: a RabbitMQ named exchange, a Pulsar topic URL, an AMQP URI carrying credentials, an IBM MQ / JMS queue, a routing-key glob |
| E2 | one RabbitMQ trace with three slow PRODUCER sends yields exactly one `slow_messaging` finding for `probe-slow-rabbitmq`, with three occurrences |
| F3 | seven crafted topologies plus order invariance, which localise any F1/F2 failure: `receive` as a sibling, as an ancestor, a sibling that started **before** the `receive` (must stay unlinked — a false link is worse than none), work under an intermediate handler, I/O under a handler that **predates** the delivery (the guard judges the attributed node, so the handler shields its whole subtree), two deliveries under one parent (the nearest preceding one wins), and all six shapes resolving identically with the payload reversed — which receive explains a span is a question about start times, so exporter ordering must not answer it |
| F1/F2 | the producer link on the **real** `astronomy-shop` capture, per slice. The rate is over the traces that are **analyzable**: half the linked consumer traces here are CONSUMER-only two-span traces, and messaging classification admits PRODUCER only, so they carry no analyzable event and never enter the analysis. `explain` cannot annotate what was never ingested |

## How it works

Self-contained: the local release binary on loopback, plus a `python3 -m
http.server` serving the committed `alumet-conformance` capture of the **real**
agent augmented with one synthetic broker-cgroup row at a known
joules-per-poll, so every figure is checkable arithmetic. **No cluster, no
Docker.**

Messaging traffic goes in over the daemon's NDJSON socket: 8 publishes to one
destination per trace clears `n_plus_one_min_occurrences = 5`, so every window
carries both `total_messaging_io_ops` and an avoidable share.

Four details that are deliberate rather than incidental:

- **The wall clock is compressed.** What triggers the double billing is
  `scrape_interval > analysis batch cadence`, not the absolute 30 s of the
  product report. The ratio is preserved (3 s scrape against a 1 s trace TTL)
  and the durations shrink accordingly, so the run takes minutes instead of an
  hour.
- **A static exposition is not enough for A4.** A real Alumet agent accumulates
  while perf-sentinel cannot reach it and hands the whole gap over on the first
  successful scrape after it returns — that catch-up is the entire reason rule 4
  exists. A constant file never catches up and the leg would pass vacuously, so
  the served value is rewritten to one outage's worth of joules for **exactly
  one** successful scrape, tracked through the daemon's own
  `perf_sentinel_alumet_scrape_total{status="success"}` counter rather than a
  fixed sleep.
- **Boot is not the nominal regime.** Before any scrape has landed the
  declaration bills legitimately — that is what A6 asserts — so A1 counts
  declared windows only from the first measured window onwards. Reading the boot
  transient as a rule-1 violation would fail the leg for being right.
- **The batch cadence is load-bearing in A4 and A7, and it is a regression
  guard.** The declared source refuses to bill a gap below `MIN_BILLABLE_MS`
  (1 s). A past revision consumed the outage marker on every stale tick, so a
  tick spaced under a second erased it without re-setting it — and the recovery
  delta was then billed twice. That is fixed (the marker is read-only on the
  stale branch now), but continuous traffic against `trace_ttl_ms = 1000`
  produces exactly the sub-second spacing that exposed it, which is why these
  legs run the seeder at 0.4 s. Spacing the windows above 1 s made both legs pass
  on a binary that was demonstrably wrong, so do not "fix" a future failure that
  way.

## Run

```bash
make verify-broker-messaging-waste
# or
./scenarios/broker-messaging-waste/verify.sh
```

Prerequisites: a local release build of the product
(`cargo build --release -p perf-sentinel`, path overridable through
`PERF_SENTINEL_LOCAL_BIN`) and `python3`. Report at
`/tmp/scenario-broker-messaging-waste-report.md`.

### A/B-ing a suspected regression

`PERF_SENTINEL_LOCAL_BIN` is the whole harness needed to attribute a failure to a
revision rather than to the test. Build both revisions aside, then run the same
scenario against each — one variable, nothing else touched:

```bash
cd "$PERF_SENTINEL_REPO_PATH"
git checkout <suspect> && cargo build --release -p perf-sentinel && cp target/release/perf-sentinel /tmp/ps-suspect
git checkout <known-good> && cargo build --release -p perf-sentinel && cp target/release/perf-sentinel /tmp/ps-good
cd -
for rev in good suspect; do
  PERF_SENTINEL_LOCAL_BIN=/tmp/ps-$rev ./scenarios/broker-messaging-waste/verify.sh
done
```

The second variable worth sweeping, once a revision is implicated, is the batch
cadence: `start_seeding` takes an interval, and moving it across the declared
source's 1 s `MIN_BILLABLE_MS` boundary is what separated "the product is wrong"
from "the test is wrong" when the outage marker regressed. Sweep one at a time;
a harness that changes both proves nothing.

## Known state and caveats

- **Leg F fails on the current branch, and the failure is the point.**
  `resolve_producer_link` walks **ancestors** only, while the real
  OpenTelemetry Java/.NET Kafka instrumentation emits the `receive` CONSUMER
  span as a **sibling** of the work it triggered, under a shared parent. On the
  committed capture: 28 linked consumer traces, 0 links surfaced. The two
  crafted shapes in `fixtures/broker_cases.py` isolate the cause to that single
  variable — same trace, same link, only the parent of the analyzable span
  differs, and only the ancestor form renders `triggered by trace`.
- **The A legs are new-feature gates, not regression gates.** 0.9.22 has no
  broker energy at all, so it produces no `messaging_waste` to compare against;
  A5 in particular confirms that the review fix holds against a real scraper, it
  cannot re-demonstrate the bug.
- **`label_value` is deliberately permissive.** A value with spaces or `!` is
  accepted: cgroup names carry odd characters, so `validate_workload_fields`
  bounds only length and control characters there. The charset rule (`ASCII
  letters, digits, '-' and '_'`) applies to **`region`**, which legs d7 and d8
  gate — they are the two rejections that flow through the validator broker and
  database share, so they are where a section mix-up would surface.
- **The RabbitMQ default exchange is a documented blind spot,** recorded as a
  note rather than a failure: `messaging.destination.name` is blank there and
  `messaging.rabbitmq.destination.routing_key` is never read, so publishes to
  distinct routing keys collapse into one template. Same class as the host-strip
  merges documented in `rpc-carrier-parity`.
- The headless TUI capture SKIPs rather than fails when no pty is available; the
  data plane it polls is asserted directly, and upstream render tests cover the
  string.
