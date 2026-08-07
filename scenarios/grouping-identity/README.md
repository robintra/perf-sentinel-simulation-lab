# Grouping identity

This self-contained scenario is the perf-sentinel 0.11 contract gate for
configurable deployment identity.

It verifies resource-before-span attribute selection, the default Kubernetes
namespace behavior, custom `tenant.id`, two groupings for one service, the
eight-key cap, 256-byte truncation and control-character rejection. The same
identity must survive OTLP HTTP, OTLP gRPC, the daemon JSON socket, per-trace
detectors, `/api/findings`, `diff`, HTML rendering and browser-generated
findings/correlations CSV files. A report without grouping remains a valid
pre-0.11 baseline.

## Run

```bash
make verify-grouping-identity
```

Prerequisites: the local `perf-sentinel` 0.11.0 release binary, Docker and
Chrome/Chromium. Override the product checkout with
`PERF_SENTINEL_REPO_PATH`; override the binary with
`PERF_SENTINEL_LOCAL_BIN`.

The report is written to `/tmp/scenario-grouping-identity-report.md`. Any
failed assertion exits non-zero; the scenario never writes the release ledger.
