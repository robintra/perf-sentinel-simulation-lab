# B2 operational mode validation

The B2 suite validates perf-sentinel operational modes that the
nominal lab path (centralized daemon + OTel Collector + Tempo) does
not exercise. Each scenario lives in `scenarios/b2-N-<name>/` and
ships a `verify.sh` plus a `README.md`.

## Coverage

| Scenario | Mode tested | Cluster deps | Status |
|---|---|---|---|
| B2-1 | hybrid daemon -> batch HTML | running daemon | PASS |
| B2-2 | batch over Tempo via `perf-sentinel tempo` | daemon + Tempo | PASS |
| B2-5 | calibrate energy coefficients | none (uses fixture + synthetic CSV) | PASS |
| B2-3 | daemon OTLP direct (no collector) | dedicated daemon + cloned service in new namespace | DEFERRED |
| B2-4 | multi-format input (Native + Jaeger + Zipkin) | Jaeger + Zipkin backends + multi-export collector | DEFERRED |
| B2-6 | sidecar pattern (1 daemon per service) | sidecar pod in new namespace | DEFERRED |

The 3 PASS scenarios reproduce reliably on a `make up-cni` + `make
seed-services` + `make seed-electricity-maps` cluster. The 3 DEFERRED
scenarios are documented and have their `verify.sh` placeholders that
exit 0 with a status message. The DEFERRED status reflects local
Docker Desktop RAM constraints observed during the initial sprint, not
a perf-sentinel bug.

## Run

```bash
# Single scenario
make verify-b2-1-hybrid-daemon-batch
make verify-b2-2-batch-tempo-scrape
make verify-b2-5-calibrate-mode

# All six (DEFERRED ones print a status line and exit 0)
make verify-b2-all
```

Each scenario writes a markdown report under
`/tmp/scenario-b2-N-<name>-report.md`.

## Scenario details

### B2-1 hybrid daemon to batch HTML

Use case: snapshot the daemon Report and render a self-contained HTML
dashboard for shareable post-mortem. No re-analysis is run on the
snapshot, the HTML reflects the daemon findings exactly.

Path validated: `perf-sentinel report --input <daemon-report.json> --output <dashboard.html>`.

Limitation: the SARIF-from-batch path requires raw traces, not a
Report JSON. See B2-2 for that.

### B2-2 batch over Tempo

Use case: a CI job that does not run a daemon 24/7 but periodically
fetches recent traces from Tempo and runs detection on them.

Path validated: `perf-sentinel tempo --endpoint http://host.docker.internal:3200 --service order-service --format json`.

This validates that item 5 of `project_perf_sentinel_followup.md`
(Tempo OTLP-JSON consumer) works end to end. The followup item is
RESOLVED in 0.5.16+.

### B2-5 calibrate energy coefficients

Use case: a customer measures power consumption on their own hardware
during a baseline trace window, then calibrates per-service energy
coefficients for accurate green-ops scoring.

Path validated: `perf-sentinel calibrate --traces <jaeger.json> --measured-energy <power.csv> --output calibration.toml`.

The verify generates a synthetic CSV in the format
`timestamp,service,power_watts` with timestamps overlapping the trace
fixture window. Real customers would replace the synthetic CSV with
metered data from their hardware.

### B2-3 daemon OTLP direct (DEFERRED)

Use case: minimal setup with no Tempo and no OTel Collector. Services
push OTLP traces straight to the perf-sentinel daemon's HTTP endpoint
on port 14318. The daemon's OTLP HTTP receiver is native (cf. daemon
logs `OTLP HTTP listening on 0.0.0.0:14318`).

Why deferred: the in-session attempt saturated the local Docker
Desktop allocation (Java services + GitLab + observability + new
dedicated daemon + cloned service caused TLS handshake timeouts on
the cluster API). Resume in a follow-up session with `make reset-cni`.

### B2-4 multi-format input (DEFERRED)

Use case: emit the same traces to three backends (Tempo OTLP, Jaeger,
Zipkin) via OTel Collector parallel exporters, run perf-sentinel
`analyze` on each format, assert the findings are coherent across
formats. Plus boundary tests on JSON parser depth (depth-31 must
parse, depth-33 must reject).

Why deferred: requires deploying Jaeger and Zipkin backends (extra
~400 MiB RAM) and reconfiguring the OTel Collector for parallel
multi-export. Combined with the existing lab footprint, this is too
much for the local Docker Desktop allocation.

### B2-6 sidecar pattern (DEFERRED)

Use case: a single application service is monitored by a perf-sentinel
daemon deployed as a sidecar in the same pod. Traces flow over
`localhost:14318` inside the pod. Useful for strict pod-level
isolation or single-service setups that do not warrant a centralized
daemon.

Why deferred: same RAM constraint as B2-3.

## Resume the deferred scenarios

```bash
# Reset cluster cleanly to free the existing footprint
make reset-cni
make seed-services
make seed-electricity-maps

# Then iterate on the deferred scenarios in risk-asc order
make verify-b2-3-daemon-otlp-direct  # currently a placeholder
make verify-b2-6-sidecar-pattern     # currently a placeholder
make verify-b2-4-multiformat-input   # currently a placeholder
```

The follow-up session needs to fill in the `verify.sh` body of the
three deferred scenarios. B2-3 has a partial `manifests.yaml` already
committed as a template.
