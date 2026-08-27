# hub-source-reachability

Push and poll do not mean the same thing to a source's reachability.

## Why it exists

The Hub tracks whether it can reach each source. Only a **successful poll**
clears that marker; a push never touches it. The asymmetry is deliberate and
easy to get backwards. A daemon can be pushing perfectly while the Hub cannot
reach it at all, and an operator reading `ok` in that state would be misled
about whether the Hub could still fall back to polling.

## Why an isolated pair, not the shared one

The zero-trust policy admits a polling Hub only from its own namespace, so a
cross-namespace poll would fail for the wrong reason and the partition would
prove nothing. The scenario therefore stands up its own daemon and Hub in one
namespace, the daemon pinned to the same image the shared deployment runs.

The partition cuts only this Hub's egress, inside its own namespace. Nothing
else in the cluster is disturbed, and `port-forward` keeps working because it
goes through the kubelet proxy rather than the pod network.

## What it asserts

1. A reachable source reads `ok` after a successful poll.
2. Under partition the poll fails and the source reads `unreachable_since`.
3. A push during the partition lands its finding **without** clearing the
   marker. Reading `ok` here would be the inversion under test.
4. Healing the partition clears the marker on the next poll tick.

One finding is seeded by push before the assertions begin: the source status is
only observable through a finding's `sources[]` array, so without a stored row
every probe would read "no source" rather than `ok` or `unreachable_since`.

The push half is issued with `curl` rather than by wiring a second daemon
exporter. What is under test is Hub-side, and the Hub cannot tell the
difference; the isolated daemon only has to answer `/api/status` and
`/api/findings`.

## Running it

```bash
make verify-hub-source-reachability
```

Needs the cluster and `make seed-hub-local` (it copies both image pins from the
shared deployments). Roughly three minutes, most of it poll ticks.
