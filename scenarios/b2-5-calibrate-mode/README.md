# B2-5 calibrate energy coefficients

## Use case

A customer wants accurate green-ops scoring on their own hardware.
They measure power consumption (in watts) during a baseline trace
window and feed both the trace JSON and the power CSV to
`perf-sentinel calibrate`. The output is a TOML file with energy
coefficients tuned per service for their environment.

## Run

```bash
make verify-b2-5-calibrate-mode
```

## What is verified

The verify script generates a synthetic CSV in the format expected by
`calibrate --measured-energy`:

```
timestamp,service,power_watts
2026-04-30T11:08:00Z,order-service,18.0
...
```

with timestamps overlapping the trace window from
`artifacts/fixtures/em-real-time-traces.json`. It runs calibrate and
asserts the output TOML contains `[calibration]`, `[calibration.services]`,
and at least one `<service> = { factor = ..., measured_energy_per_op_kwh = ... }`
entry.

## Limitations

`calibrate` is for energy coefficients, not anti-pattern thresholds
(the original brief description was incorrect on this point). The
synthetic CSV uses arbitrary 11-18 W values, so the calibrated factor
is much higher than 1.0x default and the daemon prints warnings about
"factor > 10x default, possible measurement error". This is expected
with synthetic data.

## Output

`/tmp/scenario-b2-5-calibrate-mode-report.md` plus the TOML at
`/tmp/b2-5-calibrate-mode/calibration.toml`.
