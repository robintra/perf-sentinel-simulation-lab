# batch over Tempo storage

## Use case

A user has Tempo deployed but no perf-sentinel daemon running 24/7.
A periodic batch CI job fetches recent traces from Tempo and runs
detection on them, emitting findings as JSON or SARIF.

## Run

```bash
make verify-batch-tempo-scrape
```

The Tempo port-forward (`localhost:3200`) must be active. `make up-cni`
or `scripts/port-forward.sh start` ensures this.

## What is verified

`perf-sentinel tempo --endpoint http://host.docker.internal:3200 --service order-service`
fetches traces from Tempo (which exposes only OTLP-JSON), parses them
in-process, and runs the same detection pipeline as `analyze`. The
verify asserts at least one trace is analyzed and findings are emitted.

This validates that item 5 of `project_perf_sentinel_followup.md`
(Tempo OTLP-JSON consumer) works end to end without external conversion.

## Output

`/tmp/scenario-batch-tempo-scrape-report.md`.
