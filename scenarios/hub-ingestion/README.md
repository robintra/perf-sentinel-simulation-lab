# hub-ingestion

The daemon-to-Hub chain, end to end, for the first time in any repository.

## Why it exists

The Hub's own tests drive a fake daemon. The daemon's tests never see a Hub.
Between the two sits the only link that carries the product's value: a daemon
that detects, a Hub that collects and keeps, an IDE that reads. Nothing
exercised it, so a field renamed on either side would have shipped green.

This scenario is the dependency root of the five ecosystem scenarios. If it
fails, the other four are not worth reading.

## What it asserts

1. **Findings the daemon produced come back out of the Hub.** Over the shared
   lab pair, with the daemon's real push export.
2. **The envelope stays plugin-compatible.** The daemon's own fields survive
   verbatim, and the six keys the Hub adds (`first_seen`, `last_seen`,
   `max_confidence`, `sources`, `status`, alongside the passed-through
   `stored_at_ms`) are present and internally consistent: `last_seen` never
   precedes `first_seen`, `status` is one of the three derived values, and the
   source observation carries a name, an environment, a producer version, an
   age and a status.
3. **`GET /api/findings/{traceId}` round-trips a sample trace id.**
4. **A malformed import is rejected and counted** (`RejectedCount`, event 1301)
   without poisoning the rest of the batch.
5. **The daemon's own export counters agree** that the push path is live.

## Push and poll on one source, deliberately

The lab wires both on a single source id. They mean different things to
`unreachable_since_ms` (only a successful poll clears it, a push never touches
it), and wiring them together exercises both permanently without a second
daemon. The difference itself is proven apart, in
[`hub-source-reachability`](../hub-source-reachability), which owns an isolated
pair so it can partition the network without disturbing anything else.

## Running it

```bash
make verify-hub-ingestion
```

Needs the cluster, `make seed-hub-local` and `make port-forward`.
