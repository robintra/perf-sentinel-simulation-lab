# config-fragments

The `.perf-sentinel.d/` loader introduced in 0.9.25, and the three `[green]`
deprecations that ride with it.

## Why it exists

Configuration can now be split into deterministic fragments named
`NN-lowercase-name.toml`, loaded in ascending priority order, with the main
`.perf-sentinel.toml` last. That part is a convenience. Two other things changed
at the same time and are not:

- An invalid **discovered** file stops the command with **exit 75** instead of
  discarding the valid files around it and continuing on defaults.
- That rule now covers the **implicit** `.perf-sentinel.toml` found in the
  working directory, which used to warn and carry on. A lab recipe that
  relied on the old tolerance will now fail, on purpose.

Nothing in this repository exercised either path before.

## What it asserts

| id | assertion |
|----|-----------|
| A | two fragments merge recursively: higher priority wins per key, the lower one's own keys survive |
| B | the main `.perf-sentinel.toml` loads last and beats every fragment |
| C | a duplicate priority and an uppercase name are both rejected with exit 75, naming the offender |
| D | a non-TOML file in the directory is ignored, not an error |
| E | an invalid fragment exits 75 and writes no report, with no silent fallback to defaults |
| F | an invalid **implicit** main file exits 75 too (the changed behaviour) |
| G | with `--config path/custom.toml`, fragments come from `path/.perf-sentinel.d/` and **not** from the working directory |
| H | the six reference GreenOps fragments load together; `60-daemon-docker.toml` loads as a standalone main config |
| I | the three deprecated `[green]` keys warn and are ignored |
| J | `detection_config` is stamped on the report, and a report *without* it still loads |
| K | an absent carbon figure names its **own** cause, on both paths |

G plants a decoy: a fragment in the working directory setting a value
nothing else uses. If the assertion sees that value, the loader read the
wrong directory, which a pass/fail on the merged result alone would not
catch.

I is not about fragments. It is here because it is the other half of what a
0.9.25 config load does differently, and because a lab config still carrying
those keys would otherwise show up as unexplained warning noise in some other
scenario's stderr.

J belongs here for a different reason: `detection_config` is *how* every
other leg reads its result, so if it disappeared, five assertions would fail
with an unhelpful `MISSING`. J names it directly, and checks the other side
of the same contract: a report from a binary that had no such field must
still load, which is the additivity 0.9.25 claims for it.

K is the third of that group. 0.9.25 prints absent figures greyed out with
their cause instead of omitting them, and the first version of that deduced
the cause from the presence of `scoring_config`, which is not a signal that
GreenOps ran. The daemon stamps that object as soon as Electricity Maps is
configured, `[green] enabled` notwithstanding, so a daemon in that
configuration having processed thousands of traces claimed "no traces
analyzed" on a busy window. The leg runs that exact combination (green off
*with* an electricity_maps block, which is legitimate since the scraper runs
independently of the toggle) beside the honest zero-trace case, and asserts
each names its own cause. The combined "enabled = false, or no traces
analyzed" wording no longer exists.

## What it found (2026-08-02, pre-release 0.9.25)

11/11. Three measurements worth keeping:

- **`include_network_transport = false` changes nothing.** The scenario runs
  the same analysis twice, once with the three deprecated keys set to the
  values that used to erase terms and once with none of them. It then
  asserts the two carbon totals are *identical*, not merely both present.
  The methodology tag stays `sci_v1_numerator+transport` either way. That is
  the §2.1 behaviour measured rather than assumed.
- **The three deprecations warn and keep running.** Three warnings, exit 0. A
  zeroed `embodied_carbon_per_request_gco2` falls back to the default instead of
  refusing to boot, which matters because the same code path runs at daemon
  startup: an upgrade must not turn a running daemon into a boot failure.
- **Each absent carbon figure names its own cause.** Green off with a live
  Electricity Maps scraper prints `not computed ([green] enabled = false)`.
  A run with no traces prints `not computed (no traces analyzed)`. Neither
  borrows the other's wording, which is what the first shipped version of
  this got wrong.

One cosmetic observation, reported rather than worked around: when the
**implicit main file** fails to parse, the error reads
`config fragment .perf-sentinel.toml parse error`. The main file is not a
fragment, and an operator reading that line will go looking in
`.perf-sentinel.d/`. The exit code and the behaviour are right. Only the
noun is wrong.

## How it works

Each leg is a throwaway directory under `/tmp/config-fragments/`, and
`analyze` runs from inside it against a committed native fixture. What is
analyzed does not matter: the assertions read the **loaded configuration back
out of the report**, through the `detection_config` block 0.9.25 stamps onto
every report from the run that produced it. That is a stronger check than
grepping the log, because it reports what the binary applied rather than what
the files said.

Leg H needs the product checkout for its `examples/` directory and SKIPs
cleanly without it.

## Run

```sh
cargo build --release          # in the perf-sentinel checkout
make verify-config-fragments
```

Self-contained: no cluster, no Docker, no daemon. A few seconds. Report at
`/tmp/scenario-config-fragments-report.md`.
