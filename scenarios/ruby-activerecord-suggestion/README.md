# ruby-activerecord-suggestion

Validates the `0.9.2` Ruby/ActiveRecord framework-aware suggestions
(`detect/suggestions.rs`): an N+1 from a Rails stack is enriched with a
`suggested_fix` that names the framework and recommends the idiomatic fix.

## Fixtures (OTLP only)

Instrumentation scopes are captured **only** at OTLP ingestion (Jaeger/Zipkin
carry none), so both fixtures are OTLP/protobuf payloads POSTed to
`/v1/traces`. `fixtures/generate.py` regenerates them
(`pip install opentelemetry-proto`).

- **`ruby-ar.pb`** (`service.name = rails-shop`): a Rack HTTP root plus six SQL
  children under the scope `OpenTelemetry::Instrumentation::ActiveRecord`. The
  statement is the **sanitized** Active Record form
  `SELECT * FROM orders WHERE id = $1` (params already collapsed by the OTel
  Ruby sanitizer), repeated with **varied durations** (CV > 0.5). Under the
  lab's `strict` sanitizer-aware mode the ORM scope **and** the timing variance
  are both required to reclassify the sanitized group as `n_plus_one_sql`,
  which is then enriched with `suggested_fix.framework = ruby_active_record`
  (recommendation mentions `includes` / `preload` / `eager_load`).
- **`ruby-generic.pb`** (`service.name = rails-generic`): a standard N+1 with
  distinct id literals (mode-independent) and **no** ORM scope, each SQL span
  carrying `code.filepath = app/models/order.rb`. Detection falls back to the
  `.rb` filepath → `suggested_fix.framework = ruby_generic`.

## Run

```bash
make verify-ruby-activerecord-suggestion
```

Self-contained: needs only the local release binary
(`cargo build --release -p perf-sentinel`). Launches a throwaway loopback
daemon in the lab's strict detection mode (ports 14394/14395).
