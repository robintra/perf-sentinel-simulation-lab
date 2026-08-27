# archive-window-drops

Windows the daemon dropped instead of archiving, and the counter that finally
makes them visible.

## Why it exists

The daemon hands each scored window to its archive writer over a bounded
channel and drops on full rather than blocking the analysis path. That
trade-off is right: a stalled filesystem must never stall detection. What was
wrong before 0.15.0 is that the drop left no trace anywhere.

`try_send` returned a boolean nobody read, and the hash chain could not help
either: `seq` only advances after a *successful* write, so a dropped window
leaves a chain that is still perfectly continuous. A period could lose windows
and publish a disclosure report that looked complete, with an intact chain and
a valid `content_hash`.

Since 0.15.0 each drop increments
`perf_sentinel_archive_windows_dropped_total{reason}` over a bounded
compile-time reason set (`channel_full`, `writer_exited`, `serialize_error`,
`write_error`), and each archived line carries the cumulative count so
`disclose` can fold it into `windows_dropped` for the period.

## Two legs, because one daemon run cannot prove both halves

**A. Healthy archive, a real file.** Asserts that every archived line carries a
`drops` field and that all four reasons are present at zero. The pre-warm is
part of the contract, not cosmetics: a counter that only materialises once it
fires cannot be alerted on, because `rate(...) > 0` has nothing to compare
against on a healthy fleet.

**B. Saturated archive, a FIFO.** `CHANNEL_CAPACITY` is a compile-time 256, not
a configuration knob, so the channel cannot be shrunk to force the condition
the way `daemon-analysis-shedding` shrinks its analysis queue. Pointing the
archive at a FIFO whose reader consumes nothing fills the pipe buffer, blocks
the writer inside `write_all`, backs the channel up and starts the drops. A
reader has to exist, otherwise the daemon's own open would block and holding
the read end open is also what keeps the writer blocking instead of taking an
EPIPE, which would show up as `write_error` and prove the wrong thing.

The scenario asserts `channel_full > 0` **with the other three reasons still at
zero**. That combination is the whole point: it distinguishes a saturation from
an I/O fault, which is the distinction an operator has to make at 3am.

## What this scenario deliberately does not assert

**An exact drop count.** It depends on the pipe buffer size and on how the
scheduler interleaves the writer with the analysis path. Only `> 0` and the
non-decreasing progression are safe.

**The fold arithmetic.** A blocked FIFO yields no readable lines by
construction, so this scenario cannot check how per-line counts accumulate into
a period total. That belongs to the sibling hermetic scenario
[`disclose-archive-family-baseline`](../disclose-archive-family-baseline),
which gates it on committed fixtures where the arithmetic is exact and a
regression is visible rather than merely plausible.

## Running it

```bash
make verify-archive-window-drops
```

Local release binary, no cluster, no Docker. Roughly a minute: leg B needs the
saturation window to actually fill 256 queued windows.

The daemon is stopped with SIGKILL, not SIGTERM: a graceful shutdown drains the
archive channel, which in leg B means writing hundreds of queued windows into a
FIFO nobody reads, and never returning.
