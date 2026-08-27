# hub-derived-status

`active`, `likely_resolved`, `not_observed`, and the two cases that must not
move.

## Why it exists

The status a finding carries is derived, not stored. `likely_resolved` is the
hardest of the three to reach honestly: it requires a heartbeat from a source
that has **also observed that finding**, inside the resolution grace. No pair of
endpoints in the lab shares a `(service, endpoint)` naturally, so the condition
would never fire on organic traffic and the transition would stay untested.

The scenario forges envelopes over `curl` instead, on an isolated Hub with a
`ResolutionGrace` measured in seconds.

## What it asserts

1. A freshly observed finding reads `active`.
2. When only the sibling signature keeps being reported on the same
   `(service, endpoint)`, the quiet one moves to `likely_resolved`.
3. When nothing is reported at all, it falls back to `not_observed`.
4. **Negative case, unwitnessed source.** A heartbeat from a source that never
   saw the finding must leave it `not_observed`. The status expression
   correlates on `finding_sources`, and without that correlation any busy source
   would silently vouch for a finding it never observed.
5. **Negative case, unreachable source.** A heartbeat from a source the Hub
   cannot reach must also leave it `not_observed`. Silence from an unreachable
   daemon is not evidence of a fix.

## The trap worth naming

`PollWorker` polls immediately at boot, before its first interval elapses, so a
long `PollInterval` does not stop it from polling. And an isolated Hub pointed
at the shared daemon is blocked by the lab's own same-namespace NetworkPolicy,
which sets the reachability marker for the wrong reason. This Hub polls its own
service.

## Running it

```bash
make verify-hub-derived-status
```

Needs the cluster and `make seed-hub-local`.
