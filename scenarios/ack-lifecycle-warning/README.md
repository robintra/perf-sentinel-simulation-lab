# ack-lifecycle-warning

The full life of a CI acknowledgment on real artefacts: created, matched,
fixed, not exercised — and replayed.

## Why it exists

0.9.28 surfaces an active TOML acknowledgment that suppressed nothing under the
`unmatched_acknowledgment` warning, and the optional `service` /
`source_endpoint` fields let the message split two very different situations
using the run's per-endpoint I/O counts:

| situation | message |
|---|---|
| endpoint did I/O, finding did not fire | *was exercised and the finding did not fire, the problem looks fixed and the entry can be removed* |
| endpoint emitted no I/O | *emitted no I/O in this run (not exercised, or its I/O was removed outright), so this proves nothing, keep the entry* |
| entry without the two fields | *either fixed … or the scenario that produced it did not run (add service and source_endpoint to the entry to tell the two apart)* |

The half that actually needs a lab is the **guard**. The warning must be
derived only from a fresh analysis of traces. A pre-computed report — a daemon
`/api/export/report` snapshot, or a report JSON replayed through
`report --input` — is *already ack-filtered*, so every entry still doing its
job looks unmatched there. Without the guard the tool advises deleting exactly
the acknowledgments that are working, and nothing errors out: the operator just
removes a useful entry and the finding comes back at the next release.

Unit tests can pin the message strings. What they cannot do is take a real
daemon export, a real acks file and the real CLI, and check that the advice
never appears on the replayed path.

## Legs

| id | assertion |
|----|-----------|
| A1.1 | the fixture's N+1 fires, yielding the signature, service and endpoint used below |
| A1.2 | with the ack active: finding suppressed, quality gate passes, **no** warning |
| A1.3 | same endpoint still does I/O, no finding → *looks fixed*, naming the endpoint |
| A1.4 | the acked endpoint emits no I/O while the service serves others → *proves nothing* |
| A1.5 | an entry without `service` / `source_endpoint` → indeterminate, names both readings |
| A2.1 | **positive control**: the same ack *does* warn on fresh traces |
| A2.2 | `report --input <replayed analyze JSON>` advises nothing |
| A2.3 | `report --input <daemon snapshot>` advises nothing (committed fixture, plus a live daemon when reachable) |
| A3 | `diff` carries the after run's warnings in text and in `warning_details`, and `.new_findings` stays readable for the lab's existing `jq` consumer |

A2.1 is not decoration. Both guard assertions are *silence* checks, and silence
is free on any version that never emits the warning — every release before
0.9.28 included. The control turns "nothing appeared" into evidence. Run
against a 0.9.26 binary this scenario fails five legs, A2.1 among them, and its
message says precisely that the guard checks would have passed vacuously.

A1.4 keeps the service busy on *other* endpoints on purpose: a check that keyed
on the service alone rather than on the (service, endpoint) pair would wrongly
report the endpoint as exercised.

## Prerequisites

Self-contained: the local release binary (`cargo build --release`) and python3.
No cluster, no Docker. The A2.3 leg additionally queries `DAEMON_URL`
(default `http://localhost:14318`) when a daemon answers there.

## Run

```bash
make verify-ack-lifecycle-warning
```

Knobs: `PERF_SENTINEL_LOCAL_BIN`, `PERF_SENTINEL_REPO_PATH`, `DAEMON_URL`.

Report: `/tmp/scenario-ack-lifecycle-warning-report.md`.

## Fixtures

Three native trace files sharing one service and one endpoint, so the same
acknowledgment travels all three:

- `nplusone.native.json` — 8 sibling SELECTs on `/api/orders` (the finding)
- `fixed.native.json` — the same endpoint, one batched query (I/O, no finding)
- `elsewhere.native.json` — traffic on other endpoints of the same service only

Each carries a background of 30 single-query traces on other endpoints, which
keeps `io_waste_ratio` realistic — a run that is 100 % N+1 fails the quality
gate on the ratio alone and would mask what these legs are testing.

`daemon-snapshot.json` is a real `/api/export/report` capture (8 findings) so
the guard leg runs without a cluster.

## Notes

The acks file is the documented `.perf-sentinel-acknowledgments.toml`, whose
root key is `[[acknowledged]]` (not `acknowledgments`) and whose
`acknowledged_at` is mandatory. A file with the wrong root key parses fine and
silently acknowledges nothing — there is no `deny_unknown_fields` on that
struct, which is what lets the two new optional fields be ignored everywhere
else.
