# GreenOps integration

The lab can enrich perf-sentinel findings with real-time grid
carbon intensity from the [Electricity
Maps](https://www.electricitymaps.com/) API. When the integration
is active, findings produced by the daemon carry
`intensity_source: "real_time"` instead of the bundled annual
average. The daemon report dashboard then renders a "Carbon
scoring:" banner above the green-regions table.

This is the first external GreenOps source wired into the lab. The
default zone is FR (mapped from the synthetic AWS region `eu-west-3`).

## Setup

1. Get an API token from the
   [Electricity Maps portal](https://www.electricitymaps.com/free-tier-api).
   The free **sandbox key** is enough for the lab. See the comparison
   below if you have access to a 14-day trial.
2. Save the token at the repo root:

   ```bash
   printf '%s' '<your-token>' > .electricity-maps-token
   chmod 600 .electricity-maps-token
   ```

   The file is gitignored.
3. Provision the Kubernetes Secret and roll the daemon:

   ```bash
   make seed-electricity-maps
   ```

4. Verify the integration is live:

   ```bash
   make validate-findings   # produces traffic so the daemon emits its summary
   make verify-electricity-maps
   ```

`make verify-electricity-maps` checks that the Secret exists, that the
daemon Deployment mounts `PERF_SENTINEL_EMAPS_TOKEN`, and that the
daemon export endpoint (`/api/export/report`) returns a non-null
`green_summary.scoring_config`. The scoring config is computed at
daemon startup from the configured `[green.electricity_maps]` section,
so it surfaces on the export snapshot regardless of whether traffic has
been pushed yet.

If the token is absent, the daemon starts cleanly and falls back to the
bundled `annual` carbon intensity source. `make validate-findings` still
returns 10/10 PASS in that mode. This is the documented graceful
degradation path.

## Sandbox key vs trial

| Trait                 | Sandbox key                                       | 14-day trial                       |
| --------------------- | ------------------------------------------------- | ---------------------------------- |
| Cost                  | Free, permanent                                   | Free, expires after 14 days        |
| Values                | Randomized +/- 30% around grid average            | Real grid mix                      |
| `isEstimated` field   | Always `true`                                     | Reflects upstream measurement      |
| Temporal granularity  | Silently coarsened to hourly                      | Honors the configured granularity  |
| `_disclaimer` field   | Present in JSON (the daemon ignores it silently)  | Absent                             |

The sandbox key is sufficient to exercise every UI surface in the
lab. The `Carbon scoring:` banner renders the configured values
regardless of how the upstream API coarsens them. The `Estimated`
badge reliably appears on the green-regions table because
`isEstimated: true` is forced.

## Configuration knobs

The TOML section that drives the integration lives in the perf-sentinel
ConfigMap (`manifests/perf-sentinel-daemon.yaml`):

```toml
[green.electricity_maps]
endpoint = "https://api.electricitymaps.com/v4"
emission_factor_type = "direct"
temporal_granularity = "5_minutes"

[green.electricity_maps.region_map]
"eu-west-3" = "FR"
```

| Key                    | Effect                                                                  |
| ---------------------- | ----------------------------------------------------------------------- |
| `endpoint`             | Electricity Maps API root. v4 is the current stable version.            |
| `emission_factor_type` | `direct` (operational only) or `lifecycle` (operational + embodied).    |
| `temporal_granularity` | `hourly`, `5_minutes`, etc. Sandbox always serves hourly.               |
| `region_map`           | Maps the cloud regions seen on traces to Electricity Maps zone codes.   |

The token itself is not in the TOML. It is read from the env var
`PERF_SENTINEL_EMAPS_TOKEN`, mounted from the
`perf-sentinel-electricity-maps` Secret with `optional: true` so the pod
starts whether or not the Secret exists.

## Visual proof

```bash
make capture-greenops-screenshot
```

Produces `artifacts/greenops-bandeau.png` via the documented export
pipeline:

1. `kubectl port-forward` on the daemon Service.
2. `curl /api/export/report` returns the live Report JSON. Since
   daemon 0.5.13, `green_summary.regions`, `top_offenders`, and `co2`
   are all populated by the event loop after the daemon has processed
   at least one batch.
3. The host-side `perf-sentinel report --input - --output ...` binary
   renders a self-contained HTML dashboard.
4. Chrome headless captures the GreenOps tab to PNG (the URL fragment
   `#green` activates that tab on load).

The PNG shows:

- A `Carbon scoring:` bandeau above the green-regions table, with
  three chips: one neutral `Electricity Maps v4`, one accent `direct`,
  one accent `5_minutes`.
- The green-regions table populated with at least one row (the lab
  configures `eu-west-3 -> FR`).
- An orange `Estimated` badge on each region row when the sandbox key
  is in use (the sandbox always returns `isEstimated: true`).

The screenshot script needs both the `perf-sentinel` binary (resolved
from `$PERF_SENTINEL_REPO_PATH/target/release/perf-sentinel`, then
PATH) and Chrome or Chromium. It will print actionable instructions
if either is missing.

## Where the "Carbon scoring:" line shows up

The literal `Carbon scoring: Electricity Maps v4, direct, 5_minutes`
text is printed by the perf-sentinel CLI when it renders a report in
text form. The same content surfaces in the rendered HTML dashboard
(captured by `make capture-greenops-screenshot`, see above) and in
the JSON returned by `/api/export/report` (under
`green_summary.scoring_config`). To see the text form on the host:

```bash
kubectl -n observability port-forward svc/perf-sentinel-daemon 14318:14318 &
curl -fsS http://localhost:14318/api/export/report \
  | "$PERF_SENTINEL_REPO_PATH/target/release/perf-sentinel" \
      analyze --input - --format text
```

The same content surfaces as a chip banner in the rendered HTML
dashboard (see Visual proof above) and as the `green_summary.scoring_config`
field in the JSON returned by `/api/export/report`. Daemon logs
(`kubectl logs deploy/perf-sentinel-daemon`) do not contain this line:
the daemon emits findings as NDJSON and exposes Prometheus metrics, the
human-readable rendering happens client-side.

## Troubleshooting

### The daemon falls back to `annual` even though the Secret exists

Check the daemon logs for a token rejection:

```bash
kubectl -n observability logs deploy/perf-sentinel-daemon --tail=200 | grep -i electricity
```

Common causes: a stale token, a token with leading/trailing whitespace
saved into `.electricity-maps-token`, or the daemon not having been
rolled after the Secret was created. Re-run `make seed-electricity-maps`
to force a rollout.

### `make capture-greenops-screenshot` fails on the binary lookup

Build the local perf-sentinel CLI:

```bash
cd "$PERF_SENTINEL_REPO_PATH"
cargo build --release -p sentinel-cli
```

Or install it globally:

```bash
cargo install --path "$PERF_SENTINEL_REPO_PATH/crates/sentinel-cli"
```

### `make capture-greenops-screenshot` fails on Chrome lookup

The script tests `/Applications/Google Chrome.app`,
`/Applications/Chromium.app`, then `google-chrome` and `chromium` on
PATH. Install one of those, or run the export pipeline manually and
capture the HTML in your own browser:

```bash
kubectl -n observability port-forward svc/perf-sentinel-daemon 14318:14318 &
curl -fsS http://localhost:14318/api/export/report \
  | "$PERF_SENTINEL_REPO_PATH/target/release/perf-sentinel" \
      report --input - --output artifacts/greenops-report.html
open artifacts/greenops-report.html
```

### GreenOps tab missing from the rendered HTML

The GreenOps tab registers only when the report payload carries a
non-null `green_summary.co2`. Daemon 0.5.13 emits a live green_summary
on `/api/export/report`, so the tab should appear after the daemon has
processed at least one batch. Possible causes if it's missing:

1. The daemon has not processed any events yet. `/api/export/report`
   returns `503` in that state. Push some traffic with
   `make validate-findings` and retry.
2. The running pod is on an older image. Confirm:

```bash
kubectl -n observability get pod -l app.kubernetes.io/name=perf-sentinel-daemon \
  -o jsonpath='{.items[*].spec.containers[*].image}'
```

The image tag should be `0.5.13` or higher. If it's older, run
`kubectl apply -f manifests/perf-sentinel-daemon.yaml` and wait for
the rollout.
