# grouping-metrics-split

The 0.19.0 `grouping` label on the five metric families that gained it, and the
per-`(service, grouping)` pair caps that bound the cardinality it adds.

Self-contained: a local release binary, `python3` and `curl`. No cluster, no
Docker, no Prometheus.

## Why it exists

0.19.0 puts a `grouping` label next to `service` on
`perf_sentinel_findings_total`, `perf_sentinel_slow_duration_seconds` and the
three `perf_sentinel_service_*_io_ops_total` counters. Its value is the
finding's effective grouping, the first attribute present from `[detection]
grouping_attributes`, so on Kubernetes the namespace the analysed traffic runs
in. A `checkout` deployed in two namespaces was one series in 0.18.0 and is two
now.

That split is the feature and also the risk. Every carbon and waste figure an
operator reads is a sum over these series, so a split that does not preserve
the totals rewrites all of them silently, and a split without a bound
multiplies the daemon's series count by the number of namespaces it sees.

Nothing else in the lab covers this. `grouping-identity` pins the grouping
*value* across ingestion boundaries and the JSON, HTML and CSV contracts, and
never reads `/metrics`. `limit-service-cardinality` pins the *service* caps;
the pair caps are a second, independent gate that fires after them.

## What it asserts

| Leg | Claim |
|---|---|
| A | One service name in two groupings is two series, on all five families, with the exact label arity 0.19.0 documents. |
| B | `sum by (service)` over the new label returns exactly the 0.18.0 per-service series, and `sum()` the pre-0.18 total. |
| C | Past the pair caps a pair keeps its service and folds only its grouping into `_other`, the three overflow counters move, admitted pairs stay within the documented caps, and B still holds. |
| D | `[daemon] per_grouping_labels = false` empties the label on all five families; unlike `per_service_labels` it also governs the three I/O counters; and the histogram's unlabelled series is pre-warmed at startup only when *both* knobs are off. |

Legs B and C are A/B runs, not readings. The reference side is the same traffic
replayed into a daemon with `per_grouping_labels = false`, which is by
definition the 0.18.0 shape, so the comparison needs no 0.18.0 binary. tracegen
is seeded, so the two sides receive the same bytes.

Leg C drives 110 groupings across 40 services, 4400 admitted pairs, past all
three caps (512 analysis, 256 histogram, 4096 ingest). It stays at 40 services
on purpose: that is under the lowest *service* cap, the histogram's 64, so
anything that folds folded on the grouping axis. The service overflow counters
reading 0 is what proves the two axes were not conflated.

Leg C's cross-run diff covers `service_analyzed_io_ops_total` and
`service_io_ops_total` only. The other three families are derived from findings
and inherit their run-to-run variance, which the 0.19.0 validation measured
rather than assumed: over a multi-minute stream the analysis worker batches
differently from one run to the next, `findings_total` moved by up to 16 out of
about 7100 between two runs of the same traffic at the same knob setting, and
`service_avoidable_io_ops_total`, a per-finding share, moved with it. The two
families that count I/O ops directly were identical to the unit across every
run, loaded machine included.

That variance is not the fold, so pinning the other three across long runs
would make the leg flaky for a reason it does not test. They are covered where
they are stable instead: leg B compares all five exactly on short runs, and leg
C reads the avoidable counter against its own denominator inside a single
scrape, per `(service, grouping)` pair, which is what would break if a fold
charged a numerator to a pair whose denominator went elsewhere.

## Running it

```bash
make verify-grouping-metrics-split
```

Needs a local release build of the product:

```bash
cd ~/RustroverProjects/perf-sentinel && cargo build --release --workspace
```

The scenario SKIPs with exit 0, rather than failing, when that binary is absent
and again when the daemon it starts reports no `per_grouping_labels` on
`/api/config`. The second guard is a feature probe rather than a version gate:
a release branch keeps the previous version in `Cargo.toml` until tag time, so
`--version` cannot answer the question, and a lab pinned to a pre-0.19 image
must not go red on a feature that image does not have.

Knobs:

| Variable | Default | Effect |
|---|---|---|
| `SAT_ITERATIONS` | `110` | groupings driven in leg C, lower it for a quicker local run |
| `SAT_SERVICES` | `40` | services per saturation run, keep it under 64 or the service caps fire too |
| `GMS_DAEMON_HTTP_PORT` / `GMS_DAEMON_GRPC_PORT` | `14818` / `14817` | loopback daemon ports |

Report: `/tmp/scenario-grouping-metrics-split-report.md`.

Runtime is dominated by leg C's two saturation loops, roughly five minutes
together on a laptop.
