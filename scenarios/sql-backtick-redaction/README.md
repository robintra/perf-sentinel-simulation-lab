# sql-backtick-redaction

Validates the `0.9.2` and `0.25.5` `normalize/sql.rs` changes on the local
batch CLI path (`analyze --input`, no cluster, no daemon).

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
3. **MySQL / MariaDB double-quoted values are masked (`0.25.5`, security).**
   `double-quote.otlp.json` holds four OTLP traces of six CLIENT spans,
   engine from the span attribute: `db.system=mysql`, `db.system=mariadb`
   and `db.system.name=mysql` each run
   `SELECT * FROM users WHERE email = "alice-<n>@example.com"`, and
   `db.system=postgresql` runs `SELECT "Name" FROM "Users" WHERE "Id" = <n>`.
   The three MySQL-family traces must each give exactly one `n_plus_one_sql`
   on `SELECT * FROM users WHERE email = ?`, the SARIF output must hold
   those 4 `n_plus_one_sql` results (so its leak scan never runs on an empty
   run), `example.com` must appear 0 times in the `analyze` JSON and SARIF
   output, and the PostgreSQL trace
   keeps `SELECT "Name" FROM "Users" WHERE "Id" = ?` verbatim. Before
   `0.25.5` the value stayed in the template: one template per address, no
   N+1, and the address leaked through the `serialized_calls` suggestion.
4. **Documented gap pinned.** `double-quote-gap.native.json` is native JSON
   whose `operation` is the SQL verb, so it names no engine and the
   double-quoted value stays an identifier: the value reaches the output and
   no N+1 forms. The value only shows through the `serialized_calls`
   suggestion, so the leg first requires that finding and says so when it is
   missing. Any other failure of this leg means the default changed: update
   the docs.

## Watch out

- The double-quote leg never scans the HTML report: it embeds raw spans by
  design (see the scope note below).
- The PostgreSQL trace and the gap leg pass on `0.25.4` too. They guard
  against over-masking, they do not detect the fix.
- `fixtures/generate.py` rewrites all four fixtures. The two older ones come
  out byte-identical, check `git diff` after a regeneration.

## Scope note: HTML exemplar

The `0.9.2` change this note covers is the normalized **template** (signature /
grouping path), which is clean on the canonical `analyze --format json`
output. The HTML `report` additionally embeds a raw example span whose
`target` is the captured `db.statement`, so un-sanitized literals still appear
in that exemplar. The report renderer is **not** part of the `0.9.2` commits
under test (`normalize/sql.rs` only). The scenario records this as a non-fatal
observation (worth flagging upstream) and does not gate on it.

## Run

```bash
make verify-sql-backtick-redaction
# or
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel ./scenarios/sql-backtick-redaction/verify.sh
```

Needs the local release binary (`cargo build --release -p perf-sentinel` in the
perf-sentinel checkout under test). `fixtures/generate.py` regenerates the
committed fixtures (stdlib-only).
