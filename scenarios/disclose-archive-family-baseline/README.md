# disclose-archive-family-baseline

How `disclose` keys the drop baseline when it is handed more than one archive.

## Why it exists

Since 0.15.0 every archived window carries a cumulative `drops` counter inside
the hash-chained envelope, and `disclose` folds consecutive values into the
period's `windows_dropped` and `drop_counter_resets` (schema v1.7). The counter
is daemon-lifetime, not file-lifetime, which puts the fold between two failure
modes that pull in opposite directions:

- **Reset the baseline per file** and every rotation silently loses the delta
  across its boundary. A daemon that rotated at the size cap in the middle of
  the quarter under-reports its losses, with nothing to say a boundary was
  even crossed.
- **Share one baseline across everything** and two unrelated archives
  contaminate each other. `disclose` accepts a list of inputs, and
  `resolve_files` sorts them, so one host's opening value gets diffed against
  another host's closing value. A lower opening reads as a restart: the report
  gains a `drop_counter_reset` that never happened and drops that were never
  lost.

Both regressions produce a plausible number, which is exactly why they need an
arithmetic gate rather than a smoke test. The fold keys its baseline on the
**archive family**: the file's directory plus its stem with the rotation stamp
stripped, so `archive.ndjson` and `archive-<stamp>.ndjson` in one directory
share a baseline while two hosts' `archive.ndjson` never do.

## The fixtures are built to make a regression visible

| Fixture | `drops` values | Own deltas |
| --- | --- | --- |
| `hosts/host-a.ndjson` | 0, 3, 3, 7 | 3 + 0 + 4 = **7** |
| `hosts/host-b.ndjson` | 5, 5, 9, 9 | 0 + 4 + 0 = **4** |
| `rotated/archive-20260601T090000000000000Z.ndjson` | 2, 5 | 3 |
| `rotated/archive.ndjson` | 9, 12 | 3, plus **4 across the boundary** |

The ranges overlap on purpose. Host B opens at 5 while host A closes at 7, so a
shared baseline cannot help but read a decrease.

| Behaviour | hosts | rotated |
| --- | --- | --- |
| **correct** (per family) | 11 dropped, 0 resets | 10 dropped, 0 resets |
| shared baseline | 16 dropped, 1 reset | — |
| per-file baseline | — | 6 dropped, 0 resets |

## Sub-tests

1. **Two hosts stay independent.** Both host files in one `disclose` run report
   11 dropped and 0 resets.
2. **A rotation keeps its delta.** The `rotated/` directory reports 10 dropped
   and 0 resets, the boundary delta included.
3. **A genuine restart is still counted, once.** A single family whose counter
   goes 4 → 9 → 2 → 6 reports 11 dropped and exactly 1 reset. Guarding only
   against false resets would be satisfied by never detecting a real one.

## Running it

```bash
make verify-disclose-archive-family-baseline
```

Hermetic: the binary under validation runs over the committed fixtures, no
cluster and no daemon contact. The fixture report bodies are borrowed from the
`disclose` scenario, so only the `ts` and `drops` fields carry meaning here.
