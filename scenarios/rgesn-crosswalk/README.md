# `rgesn-crosswalk` scenario

Locks the **0.8.13 gate G2**: the RGESN 2024 crosswalk surfaced on
`applications[].anti_patterns[].rgesn_criteria` in an internal disclosure
(`--confidentiality internal` = per-anti-pattern detail).

Asserts the exact detector → RGESN criteria mapping:

| detector                              | RGESN                         |
|---------------------------------------|-------------------------------|
| `n_plus_one_sql`, `n_plus_one_http`   | `7.1`, `6.1`                  |
| `redundant_sql`, `redundant_http`     | `7.1`, `6.5`                  |
| `chatty_service`                      | `4.9`, `4.10`, `6.1`          |
| `excessive_fanout`, `pool_saturation` | `3.2`                         |
| `serialized_calls`                    | `8.10`                        |
| `slow_sql`, `slow_http`               | *field omitted from the wire* |

Hermetic: `analyze` the committed multi-pattern fixture
`artifacts/fixtures/em-real-time-traces.json` (yields `n_plus_one_sql`,
`n_plus_one_http`, `redundant_sql/http`, `chatty_service`, `excessive_fanout`,
`serialized_calls`, `slow_http`), wrap the report as one archived window, then
`disclose --intent internal`. Reuses the committed disclose org-config.

## Run

```
make verify-rgesn-crosswalk
PERF_SENTINEL_VERSION=0.8.13-rc make verify-rgesn-crosswalk   # pre-release
```
