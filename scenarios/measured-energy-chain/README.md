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
  the daemon has scraped both `/redfish/v1/Chassis/1/Power` and
  `/redfish/v1/Chassis/2/Power` within `REDFISH_WAIT_SEC` (default
  75s, slightly more than one full 60s Redfish scrape cycle).

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
`kepler_container_joules_total`. If the daemon config is switched to
a process variant, the mock will return zero samples and the scenario
will FAIL at 7.A.

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
