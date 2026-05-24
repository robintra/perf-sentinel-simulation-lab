# measured-energy-chain

Locks the Kepler and Redfish scraper integrations introduced in
perf-sentinel v0.7.4. Both sources are daemon-only and disabled by
default in production deployments, but the lab opts them in via
`[green.kepler]` and `[green.redfish]` blocks in
`manifests/perf-sentinel-daemon.yaml`, backed by two Python stdlib
mocks (`manifests/kepler-mock.yaml`, `manifests/redfish-mock.yaml`).

## Sub-tests

- **7.A kepler-mock integration**: the kepler-mock pod is Ready and
  the daemon has scraped `/metrics` within `KEPLER_WAIT_SEC` (default
  20s, which gives the daemon's 5s scrape interval at least three
  chances to hit the mock).
- **7.B redfish-mock integration**: the redfish-mock pod is Ready and
  the daemon has scraped `/redfish/v1/Chassis/1/Power` (legacy_power
  schema) and `/redfish/v1/Chassis/2/EnvironmentMetrics`
  (environment_metrics schema) within `REDFISH_WAIT_SEC` (default
  75s, slightly more than one full 60s Redfish scrape cycle).
- **7.C kepler happy path**: the daemon log scoped to the scenario
  window contains zero `Kepler endpoint replied HTTP 200 but no
  samples matched` warns. The absence of that warn over a window
  longer than `ZERO_SAMPLE_WARN_THRESHOLD` (3 ticks) is the direct
  evidence that the mock's metric name matches the daemon's parser
  expectation. Together with 7.A (the scrape happens) this proves
  the wire-format fidelity, the way sub-test 7 of
  `scaphandre-mock-validation` does for Scaphandre labels.

## What this scenario does NOT cover

Precedence selection across `electricity_maps_api > scaphandre_rapl >
kepler_ebpf > redfish_bmc > cloud_specpower > io_proxy_v{3,2,1}` is
locked by upstream unit tests in
`crates/sentinel-core/src/score/region_breakdown.rs:247-265`. Testing
it from the lab would require mutating the daemon ConfigMap to make
each higher-rank source unreachable and re-rolling the daemon between
sub-tests, similar to `cold-start-edge-cases` 6.D. That overhead is
deferred until a real regression appears.

`metric_kind` variants other than `container` (i.e. `process_package`
and `process_dram`) are not exercised: the Kepler mock only emits
`kepler_container_cpu_joules_total` (Kepler v0.10+ canonical name).
If the daemon config is switched to a process variant, the mock will
return zero samples and the scenario will FAIL at 7.A.

The pre-v0.10 legacy name `kepler_container_joules_total` lives in
`manifests/kepler-mock-legacy.yaml` as an opt-in negative fixture
for the daemon's zero-sample safety net; not exercised by this
scenario.

The Redfish `power_path` is left at the default
`/PowerControl/0/PowerConsumedWatts` JSON pointer. Custom pointers
(e.g. HPE iLO `/Oem/Hp/PowerSummary/Watts`) are not exercised.

## Pre-conditions

- Daemon ConfigMap contains `[green.kepler]` and `[green.redfish]`
  blocks pointing at `kepler-mock.observability.svc.cluster.local`
  and `redfish-mock.observability.svc.cluster.local` respectively.
- Both mocks are deployed and Ready. `make up-cni` already applies
  them via `scripts/bootstrap.sh:deploy_measured_energy_mocks`;
  otherwise run `make seed-kepler-mock seed-redfish-mock` manually.
- NetworkPolicy rules `perf-sentinel-daemon-kepler-egress`,
  `kepler-mock-allow-daemon`,
  `perf-sentinel-daemon-redfish-egress`,
  `redfish-mock-allow-daemon` are applied (part of
  `manifests/network-policies.yaml`).
