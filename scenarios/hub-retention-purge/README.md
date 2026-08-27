# hub-retention-purge

Retention deletes findings. It must not delete the history they carried.

## Why it exists

The Hub purges rows whose last sighting fell outside the retention window. A
superseded finding is exactly the kind of row that goes first, and its
successor's whole claim to an accurate age rests on the predecessor's birth
date. That date is denormalized onto the successor's lineage row on purpose,
and `finding_lineage` is deliberately absent from the purge statement. Neither
half was asserted anywhere.

## How a purge is forced without waiting a day

`RetentionWorker` purges once at startup and then every 24 hours, so a
`kubectl rollout restart` triggers a real pass immediately. Retention is set to
seconds here; the shared lab Hub keeps the 180-day default.

`HubOptionsValidator` refuses a `ResolutionGrace` at or above the retention, so
this Hub runs a one-second grace. Nothing here reads the derived status.

A PVC rather than an emptyDir: the restart is the trigger, so the database has
to survive it. It also lets a Job run the image's `backup` argv mode against
the same volume.

## What it asserts

1. A predecessor and its successor are both stored, lineage linked.
2. The boot purge drops the stale predecessor and keeps the successor, which
   was re-imported after the cutoff so its `last_seen_ms` fell back inside the
   window.
3. The survivor's lineage still names the original birth, at the same depth. A
   lost origin here would mean the age of the surviving problem reset to its own
   first sighting.
4. `backup` produces a database a **second Hub** can open and serve from, with
   the same lineage. That proves more than a header sniff: a file that opens,
   migrates and answers `/api/findings` is a usable backup.

## What this scenario deliberately does not assert

**Upgrading a database written before the lineage columns existed.**
`EnsureLineageColumnsAsync` is covered by a unit test in the Hub repository
instead. Staging a pre-migration file into a cluster volume needs an init
container and a hand-built SQLite blob, and buys less than the test that sits
next to the code.

**The retention cadence in steady state.** Only the boot pass is reachable
without waiting a day.

## Running it

```bash
make verify-hub-retention-purge
```

Needs the cluster and `make seed-hub-local`. Roughly two minutes, most of it the
retention wait (`HUB_RETENTION_SECS`, 30 by default).
