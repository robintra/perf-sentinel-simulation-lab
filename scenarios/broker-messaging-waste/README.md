# broker-messaging-waste

Gates the two coupled blocks added on top of 0.9.22: **OTel messaging
ingestion** and **broker energy attribution**.

Broker spans (Kafka, RabbitMQ, Pulsar, SQS, NATS, JMS) used to be dropped as
`not_io`, so an architecture built on a bus read as analysed while half of its
business path was mute. They become `EventType::Messaging` with two finding
types (`n_plus_one_messaging`, `slow_messaging`) and a producer → consumer edge
resolved through OTel span links.

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
three times in review, each correction revealing the next, so legs A1–A6 map 1:1
onto the four rules the current code rests on.

## What it asserts

| leg | assertion |
|-----|-----------|
| D  | six configuration cases: half-declared `[green.broker_static]` (`nodes` without `instance_type`), `provider = "asw"`, the broker cgroup colliding with `service_mappings`, the same cgroup declared as both broker and database, and `[green.alumet.broker]` without an `[green.alumet]` endpoint — all refused at load, the last one naming **that** section and not `[green.alumet.database]`; plus `provider = ""` **accepted** and resolved to `generic` |
| A1 | nominal regime, Alumet live and labelled: `messaging_waste.model` is `alumet_rapl` in every window once the measurement owns the timeline, and `broker_specpower` bills none of them |
| A2 | the energy summed over the run is the cgroup's own (closed form: `elapsed × J / (energy_interval × 3.6e6)`), not the declared cluster's. A per-tick double billing — the arbitration's first failure mode — lands near 2× and cannot hide in the band |
| A3 | Alumet cut: falls back to `broker_specpower` once past the staleness window (3× the scrape interval), leaving no window without a figure |
| A4 | Alumet back, handing over the whole outage in one catch-up reading: that retroactive delta covers wall clock the declaration already billed and must be dropped exactly once |
| A5 | healthy endpoint, `label_value` absent from the exposition: `broker_specpower` continuously and `messaging_waste` **present**. This is the review regression — an endpoint that answers without the label measures nothing and must not suppress the fallback |
| A6 | daemon booted with Alumet unreachable: the declaration bills from the first windows. A state never scraped must not read "fresh" while it waits out its first staleness window |
| B  | disclosure v1.5: `aggregate.messaging_waste` with its three provenance buckets and the invariant `measured + declared + estimated == windows_with_figure`; a `broker_static`-only period giving `measured_windows = 0` (a shape no unit test exercised); the **v1.4 disclosure written by 0.9.22** still verifying under this binary; and no messaging block or `declared_*` field invented on a bus-free period |
| C  | `Broker waste` on `/api/export/report`, in `query monitor`'s Energy tab and in the HTML dashboard, with no flicker across windows |
| E  | destination spellings the lab has no emitter for: a RabbitMQ named exchange, a Pulsar topic URL, an AMQP URI carrying credentials, an IBM MQ / JMS queue, a routing-key glob |
| F  | the producer link on the **real** capture: the `astronomy-shop` slices carry genuine Kafka CONSUMER spans with links, and two crafted shapes isolate whether the `receive` span sits as an ancestor or a sibling of the work it triggered |

## How it works

Self-contained: the local release binary on loopback, plus a `python3 -m
http.server` serving the committed `alumet-conformance` capture of the **real**
agent augmented with one synthetic broker-cgroup row at a known
joules-per-poll, so every figure is checkable arithmetic. **No cluster, no
Docker.**

Messaging traffic goes in over the daemon's NDJSON socket: 8 publishes to one
destination per trace clears `n_plus_one_min_occurrences = 5`, so every window
carries both `total_messaging_io_ops` and an avoidable share.

Three details that are deliberate rather than incidental:

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
- **A pre-existing gap, out of scope here.** An invalid `label_value` (spaces,
  `!`) is accepted at load on the `watch` path for **both**
  `[green.alumet.broker]` and `[green.alumet.database]`; 0.9.22 accepts it too,
  so it is not a regression of this branch and leg D does not gate it.
- **The RabbitMQ default exchange is a documented blind spot,** recorded as a
  note rather than a failure: `messaging.destination.name` is blank there and
  `messaging.rabbitmq.destination.routing_key` is never read, so publishes to
  distinct routing keys collapse into one template. Same class as the host-strip
  merges documented in `rpc-carrier-parity`.
- The headless TUI capture SKIPs rather than fails when no pty is available; the
  data plane it polls is asserted directly, and upstream render tests cover the
  string.
