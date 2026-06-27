# rails-svc

Ruby on Rails 8 (API-only) + Active Record multistack member, port **8094**,
schema **rails**. It reproduces the same 10 perf-sentinel anti-patterns as the
other stacks (see `docs/MULTISTACK.md`), but its reason to exist is the
**`OpenTelemetry::Instrumentation::ActiveRecord` scope**: the ORM marker the
0.9.2 daemon maps to `suggested_fix.framework = ruby_active_record`.

## Anatomy

- `config/` — minimal Rails app (`application.rb` API-only, `routes.rb`,
  `database.yml` driven by the `DB_*` env vars, `puma.rb` single-mode binding
  `HTTP_PORT`).
- `config/initializers/opentelemetry.rb` — `OpenTelemetry::SDK.configure` with
  `use_all`: Rails (Rack SERVER span + ActiveRecord ORM scope + ActionPack),
  Net::HTTP (outbound CLIENT spans), PG (raw pool-saturation connections). The
  OTLP HTTP exporter honours `OTEL_EXPORTER_OTLP_ENDPOINT` / `_PROTOCOL`.
- `app/controllers/fault_controller.rb` — the 10 fault endpoints.
- `app/models/` — `Order`, `OrderItem`, `Payment`.
- `lib/schema_bootstrap.rb` — idempotent table create + 100/500/200 seed under
  a PG advisory lock (mirrors django-svc).

## The ActiveRecord scope nuance (important)

The OpenTelemetry Active Record instrumentation only wraps `_query_by_sql`
(record loads / `find_by_sql`) in a span under
`OpenTelemetry::Instrumentation::ActiveRecord`. Aggregates like `.count` skip
that path and produce **only** an adapter-level `OpenTelemetry::Instrumentation::PG`
span — which the daemon would classify as `ruby_generic`, not
`ruby_active_record`. So the SQL faults here deliberately **load records**
(`Model.where(...).to_a`, `Model.find_by_sql(...)`), which is also the more
realistic Rails N+1 shape. The resulting span scope chain is
`[PG, ActiveRecord, Rack]`, which the suggestions engine resolves to
`ruby_active_record`. `pool-saturation` keeps using raw `pg` connections (PG
scope) by design, exactly like django/nest.

## Run

```bash
make seed-rails-svc                              # build + import + helm install (needs the cluster)
scripts/run-multistack-scenario.sh rails         # drive the 10 faults + grade findings
```

Verified end to end without a cluster by running the image against a local
Postgres + a local `perf-sentinel watch` 0.9.2 daemon: a
`POST /api/fault/n-plus-one-sql` produced an `n_plus_one_sql` finding with
`instrumentation_scopes = [PG, ActiveRecord, Rack]` and
`suggested_fix.framework = ruby_active_record`.
