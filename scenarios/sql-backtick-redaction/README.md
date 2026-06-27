# sql-backtick-redaction

Validates the `0.9.2` `normalize/sql.rs` changes on the local batch CLI path
(`analyze --input`, no cluster, no daemon).

## What it checks

1. **MySQL backtick identifiers are preserved.** The fixture's table is the
   numeric identifier `` `2024` `` (a year-partitioned table). Before `0.9.2`
   the tokenizer had no backtick state, so the digits between backticks were
   extracted as a numeric literal and the identifier was masked to `` `?` ``.
   With the `InBacktick` state the identifier survives verbatim, while the
   bound `` `id` = 1..6 `` literals still collapse to `?`, grouping the six
   occurrences as one `n_plus_one_sql`.
2. **PostgreSQL bracket / array string literals are masked (security).**
   `ARRAY['secret', 'pii']` and `data['ssn']` normalize to `ARRAY[?, ?]` and
   `data[?]`. `[` is deliberately *not* a special identifier state, so the
   `'...'` string path masks the contents. The whole `analyze --format json`
   output is scanned: params are never serialized, so any `secret`/`pii`/`ssn`
   hit would be a real leak (there are none).

## Scope note: HTML exemplar

The `0.9.2` change under test is the normalized **template** (signature /
grouping path), which is clean on the canonical `analyze --format json`
output. The HTML `report` additionally embeds a raw example span whose
`target` is the captured `db.statement`, so un-sanitized literals still appear
in that exemplar. The report renderer is **not** part of the three commits
under test (`normalize/sql.rs` only). The scenario records this as a non-fatal
observation (worth flagging upstream) and does not gate on it.

## Run

```bash
make verify-sql-backtick-redaction
# or
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel ./scenarios/sql-backtick-redaction/verify.sh
```

Needs the local release binary (`cargo build --release -p perf-sentinel` in the
perf-sentinel checkout under test). `fixtures/generate.py` regenerates the two
committed native fixtures (stdlib-only).
