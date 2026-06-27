# Multistack service contract

This document is the canonical contract every multistack service in this lab
must respect. The lab currently runs 3 Java/Spring Boot services
(`order-service`, `payment-service`, `notification-service`) and is being
extended with 12 additional services across distinct stacks (Quarkus,
Quarkus+Mutiny, Helidon SE, Helidon MP, .NET 10, Rust+Diesel, Rust+SeaORM,
NestJS, Django, FastAPI, Go, Rails).

Every new stack reproduces the **same 10 perf-sentinel anti-patterns** in its
own native runtime/ORM/HTTP-client. This makes perf-sentinel's detectors
validated against the wire-format diversity an operator hits in production,
not just against one canonical implementation.

## HTTP contract: 10 fault endpoints + 3 business endpoints

### Fault endpoints (the 10 anti-patterns)

Each service MUST expose all 10 endpoints below, with the exact path, method,
query parameter, and JSON response shape. Behaviour is stack-specific but
must produce the corresponding finding type when scraped by perf-sentinel
through the cluster OTel Collector.

| Method | Path                         | Query param (default)   | Anti-pattern produced |
|--------|------------------------------|-------------------------|-----------------------|
| POST   | `/api/fault/n-plus-one-sql`  | `items=15`              | `n_plus_one_sql`      |
| POST   | `/api/fault/n-plus-one-http` | `recipients=10`         | `n_plus_one_http`     |
| POST   | `/api/fault/redundant-sql`   | `repeats=10`            | `redundant_sql`       |
| POST   | `/api/fault/redundant-http`  | `repeats=10`            | `redundant_http`      |
| POST   | `/api/fault/slow-sql`        | `delayMs=600&repeats=6` | `slow_sql`            |
| POST   | `/api/fault/slow-http`       | `delayMs=600&repeats=6` | `slow_http`           |
| POST   | `/api/fault/fanout`          | `width=40`              | `excessive_fanout`    |
| POST   | `/api/fault/chatty`          | `calls=30`              | `chatty_service`      |
| POST   | `/api/fault/serialized`      | `steps=6`               | `serialized_calls`    |
| POST   | `/api/fault/pool-saturation` | `concurrency=20`        | `pool_saturation`     |

All endpoints return HTTP 200 with the JSON shape below.

### Response shape

```json
{
  "antiPattern": "n_plus_one_sql",
  "service": "quarkus-svc",
  "durationMs": 245,
  "details": { "...stack-specific keys..." },
  "timestamp": "2026-05-24T10:45:30.123Z"
}
```

Required fields:

- `antiPattern` (string) — exact snake_case name matching the finding type.
- `service` (string) — must equal `OTEL_SERVICE_NAME`.
- `durationMs` (integer) — wall-clock duration of the fault.
- `details` (object) — stack-specific. At minimum the input parameter and a
  count of operations performed (e.g. `{"items": 15, "rows_seen": 75}`).
- `timestamp` (ISO-8601, UTC) — instant the response is built.

### Behaviour notes per anti-pattern

These are the invariants the perf-sentinel detectors rely on. Reproduce them
faithfully in the stack-specific ORM/HTTP client, not "something that looks
similar".

- `n-plus-one-sql` — loop of N distinct SQL statements (interpolated literals,
  not prepared parameters), e.g. `SELECT count(*) FROM <schema>.order_items
  WHERE order_id = 1`, `WHERE order_id = 2`, …. Each statement must reach
  the JDBC/driver layer as a separate template so the OTel instrumentation
  emits N distinct spans.
- `redundant-sql` — loop of N identical SQL statements with identical literal
  parameters, e.g. `SELECT count(*) FROM <schema>.payments WHERE customer_id
  = 1` repeated 10 times. The sanitizer must see one template repeated.
- `slow-sql` — N statements each delayed server-side via `SELECT pg_sleep(0.6)`
  (or driver-equivalent), interpolated literals so each is distinct.
- `pool-saturation` — pool size must be capped at 10 in the stack's connection
  pool config (Hikari for Spring, Agroal for Quarkus, EFCore pool, etc.).
  Then launch `concurrency=20` parallel tasks each holding a connection
  ~400ms, so 10 tasks queue behind 10 in-flight ones.
- `n-plus-one-http` — N outbound HTTP calls to a local endpoint, each with a
  distinct query template (e.g. `/api/external/mock?recipient=1, =2, …`).
- `redundant-http` — N identical outbound HTTP calls, same URL same params.
- `slow-http` — N outbound HTTP calls to `/api/external/mock?delayMs=600`.
- `fanout` — N parallel outbound HTTP calls (executor / virtual threads /
  Promise.all / tokio::join_all / goroutines), each to
  `/api/external/mock?delayMs=10`.
- `chatty` — N sequential outbound calls with varying templates
  (`?seq={i}&op={i%7}`). Distinct templates avoid the n+1 classification.
- `serialized` — 6 sequential calls to `/api/dispatch/email`, `…/sms`,
  `…/push`, `…/webhook`, `…/slack`, `…/teams`, each `delayMs=80`, so the
  total wall-clock crosses ~480ms.

### Business endpoints (cross-service reach)

Each service exposes a small business surface that other services (or its
own fault endpoints) can call to exercise HTTP-side anti-patterns without
depending on cross-service infrastructure. Method is `GET`, content type is
`application/json`.

| Path                      | Query params                 | Purpose                                                                                                                                                       |
|---------------------------|------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `/api/external/mock`      | `delayMs={d}&seq={i}&op={n}` | Light parameterized endpoint, used by `n-plus-one-http`, `chatty`, `fanout`, `slow-http`. Server sleeps `delayMs` milliseconds before returning a small JSON. |
| `/api/dispatch/{channel}` | `delayMs={d}`                | Six channels (`email`, `sms`, `push`, `webhook`, `slack`, `teams`), each with the same delay-then-respond behaviour. Used by `serialized`.                    |
| `/api/payments/history`   | `customerId={id}&limit={n}`  | Returns up to `limit` payment rows for a customer from this service's schema. Used by `redundant-http`.                                                       |

These keep each service self-sufficient: a stack's HTTP-side fault endpoints
call back into its own business surface, so the fault works even if no other
multistack service is deployed.

### Health endpoints

Every service MUST expose:

- `GET /q/health/live` (or stack-equivalent: `/actuator/health/liveness`,
  `/health`, `/healthz`, etc.) — HTTP 200 when the process is up.
- `GET /q/health/ready` (or equivalent) — HTTP 200 when the connection pool
  is initialised and the schema migrations have run.

The Kubernetes deployment manifest wires these into `livenessProbe` /
`readinessProbe` with a 5s initial delay and a 10s period. Stack-specific
paths are documented in each service's `README.md`.

## Service inventory

The lab namespace `shop` hosts all services. New stacks land on ports 8083
through 8094 (Java baseline keeps 8080-8082). Each service owns its own
Postgres schema in the shared `lab` database.

| Service              | Port | Schema        | Stack                                       |
|----------------------|------|---------------|---------------------------------------------|
| order-service        | 8080 | orders        | Spring Boot 4.0.6 + JPA (existing baseline) |
| payment-service      | 8081 | payments      | idem                                        |
| notification-service | 8082 | notifications | idem                                        |
| quarkus-svc          | 8083 | quarkus       | Quarkus 3.33.1.1 LTS + Panache              |
| mutiny-svc           | 8084 | mutiny        | Quarkus 3.33.1.1 LTS + reactive PG client   |
| helidon-se-svc       | 8085 | helidon_se    | Helidon SE 4.4.0                            |
| helidon-mp-svc       | 8086 | helidon_mp    | Helidon MP 4.4.0 + JPA                      |
| dotnet-svc           | 8087 | dotnet        | .NET 10 + EF Core 10                        |
| diesel-svc           | 8088 | diesel        | Rust 1.95 + Diesel 2.3                      |
| seaorm-svc           | 8089 | seaorm        | Rust 1.95 + SeaORM 1.1                      |
| nest-svc             | 8090 | nest          | NestJS 11 + Prisma 7.8                      |
| django-svc           | 8091 | django        | Django 5.2 LTS + psycopg 3                  |
| fastapi-svc          | 8092 | fastapi       | FastAPI 0.136 + SQLAlchemy 2 async          |
| go-svc               | 8093 | go            | Go 1.26 + pgx v5                            |
| rails-svc            | 8094 | rails         | Rails 8 + Active Record (Ruby 3.3)          |

Cluster-internal DNS:
`http://<svc-name>.shop.svc.cluster.local:<port>`.

### Pinned versions (verified 2026-05-24)

Strategy: **LTS wherever the project offers one**, otherwise latest
stable. Re-verify before each Dockerfile bump.

| Component       | Pinned version               | LTS?                                                                  | Notes                                                           |
|-----------------|------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------|
| Quarkus         | **3.33.1.1** (2026-05-04)    | Yes — Quarkus 3.33 LTS line, ~12-month support, EOL ~2027-03          | Latest non-LTS 3.35.4 not chosen on purpose.                    |
| Mutiny          | **3.2.0** (2026-04-28)       | No LTS                                                                | Bundled in Quarkus BOM.                                         |
| Helidon SE      | **4.4.0** (2026-03-17)       | Yes — Java Verified Portfolio LTS, next Tip is Helidon 27 (Sept 2026) | See Helidon notes section below.                                |
| Helidon MP      | **4.4.0** (MicroProfile 6.1) | Yes — same JVP LTS                                                    | idem                                                            |
| .NET runtime    | **10.0.8** (2026-05-12)      | Yes — .NET 10.0 LTS, EOL 2028-11-14                                   | C# 14 ships with .NET 10.                                       |
| EF Core         | **10.0.8** (2026-05-12)      | Yes — ships in lockstep with .NET 10 LTS                              | + Npgsql.EntityFrameworkCore.PostgreSQL 10.0.1                  |
| Rust            | **1.95.0** (2026-04-16)      | No LTS (6-week cadence)                                               | 1.96 not yet shipped at 2026-05-24.                             |
| Diesel          | **2.3.9** (2026-04-30)       | No LTS                                                                | + `diesel-async 0.7` optional.                                  |
| SeaORM          | **1.1.20** (2026-03-31)      | No LTS                                                                | 2.0 line still in RC at 2026-05-24, do not use yet.             |
| NestJS          | **11.1.23** (2026-05-21)     | No LTS                                                                | v12 ESM-only milestone targeted Q3 2026.                        |
| Node.js runtime | **24 "Krypton" Active LTS**  | Yes — Active LTS, EOL ~2028-04                                        | Node 22 is Maintenance LTS only.                                |
| Prisma          | **7.8.0** (2026-04-22)       | No LTS                                                                | Prisma 7 GA was 2025-11-19.                                     |
| Django          | **5.2.14 LTS** (2026-05-05)  | Yes — security support through ~April 2028                            | 6.0.5 latest non-LTS not chosen. Next LTS is 6.2 (~April 2027). |
| FastAPI         | **0.136.3** (2026-05-23)     | No LTS                                                                | Pydantic ≥ 2.13 required.                                       |
| Go              | **1.26.3** (2026-05-07)      | No LTS (6-month cadence, N and N-1)                                   | + `pgx v5.7.5`.                                                 |
| Rails           | **8.x** (Active Record)      | No LTS                                                                | Ruby 3.3; opentelemetry-instrumentation-rails + active_record. |
| Ruby            | **3.3** (slim-bookworm)      | Stable                                                               | The ActiveRecord ORM scope is emitted by record loads (`_query_by_sql`), not `.count`. |

Verification sources (re-fetched per stack at delivery time):

- Quarkus: https://github.com/quarkusio/quarkus/releases + https://quarkus.io/blog/tag/release/
- Mutiny: https://github.com/smallrye/smallrye-mutiny/releases
- Helidon: https://github.com/helidon-io/helidon/releases + Medium release post
- .NET / EF Core: https://github.com/dotnet/runtime/releases + https://github.com/dotnet/efcore/releases
- Rust: https://blog.rust-lang.org/category/releases/
- Diesel: https://github.com/diesel-rs/diesel/releases
- SeaORM: https://github.com/SeaQL/sea-orm/releases
- NestJS: https://github.com/nestjs/nest/releases
- Node.js: https://nodejs.org/en/about/previous-releases
- Prisma: https://github.com/prisma/prisma/releases
- Django: https://www.djangoproject.com/download/
- FastAPI: https://github.com/fastapi/fastapi/releases
- Go: https://go.dev/doc/devel/release

## Postgres conventions

The `lab` database is shared. Each service owns its schema, named exactly as
the service slug without the `-svc` suffix (e.g. `quarkus`, `helidon_se`).
Underscores replace hyphens since SQL identifiers cannot contain hyphens
without quoting.

Each schema MUST contain at minimum three tables that match the Java
baseline's shape, so the fault endpoints can target consistent queries:

- `<schema>.orders` — at least 100 rows, columns `id` (PK), `customer_id`,
  `total_cents`, `status`, `created_at`.
- `<schema>.order_items` — at least 500 rows (5 per order on average),
  columns `id` (PK), `order_id` (FK), `product_id`, `quantity`, `unit_cents`.
- `<schema>.payments` — at least 200 rows, columns `id` (PK), `order_id`,
  `customer_id`, `amount_cents`, `status`, `created_at`.

Seed data is the responsibility of the service's own migration tool (Flyway,
EF Core migrations, diesel-cli, sea-orm-cli, Prisma migrate, django migrate,
alembic, golang-migrate, Active Record / a startup bootstrap).

The shared schema bootstrap (schema + role + GRANT + search_path) for the 12
new services lives in `manifests/postgres-multistack-schemas.yaml` as a
Kubernetes Job. It must be applied once before any new service comes up,
and is idempotent (`CREATE SCHEMA IF NOT EXISTS`, `CREATE ROLE` guarded by
`pg_roles` lookup).

## OpenTelemetry wiring

Every service MUST export traces (only traces, not logs or metrics) to the
shared OTel Collector via OTLP HTTP/protobuf. The Collector then forwards
to perf-sentinel on the cluster.

Environment variables to set on each service container:

```
OTEL_SERVICE_NAME=<svc-name>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector-opentelemetry-collector.observability.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_SAMPLER=always_on
OTEL_LOGS_EXPORTER=none
OTEL_METRICS_EXPORTER=none
OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,deployment.environment=lab,cloud.region=eu-west-3,cloud.provider=aws
```

Stack-specific instrumentation choice:

- **Quarkus / Mutiny**: prefer the `quarkus-opentelemetry` extension over the
  Java agent. Auto-instruments JAX-RS, JDBC (Agroal), RestClient.
- **Helidon**: built-in `helidon-telemetry` module, exports OTLP natively.
- **.NET 10**: `OpenTelemetry.AspNetCore` + `OpenTelemetry.Instrumentation.EntityFrameworkCore`
  + `OpenTelemetry.Exporter.OpenTelemetryProtocol`, configured in `Program.cs`
  via the `ResourceBuilder` and `TracerProviderBuilder` chain.
- **Rust** (Diesel / SeaORM): `opentelemetry-rust 0.30` + `tracing-opentelemetry`
  + `opentelemetry-otlp`, initialised at startup. HTTP layer instrumented via
  `tower-otel-http-metrics` or equivalent.
- **NestJS**: `@opentelemetry/sdk-node` (or `@opentelemetry/auto-instrumentations-node`)
  configured at `main.ts` boot.
- **Django / FastAPI**: `opentelemetry-instrumentation-django` /
  `opentelemetry-instrumentation-fastapi` + `opentelemetry-instrumentation-psycopg`
  / `opentelemetry-instrumentation-sqlalchemy`.
- **Go**: `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`
  middleware + `go.opentelemetry.io/contrib/instrumentation/database/sql/otelsql`
  wrapper.

## Process map (perf-sentinel Scaphandre integration)

Every service MUST appear in `manifests/perf-sentinel-daemon.yaml` under
`[green.scaphandre.process_map]` with `exe_contains` matching the runtime's
absolute path:

- Java distroless: `exe_contains = "bin/java"`
- .NET chiseled: `exe_contains = "/dotnet"`
- Rust static: `exe_contains = "/usr/local/bin/<svc>-bin"` (path of compiled binary)
- Node distroless: `exe_contains = "bin/node"`
- Python distroless: `exe_contains = "bin/python3"`
- Go static: `exe_contains = "/usr/local/bin/<svc>-bin"`
- Ruby slim: `exe_contains = "bin/ruby"`

`cmdline_contains` is the service slug (e.g. `quarkus-svc`) so identical
runtimes (multiple Java services) stay disambiguated. The Scaphandre mock at
`manifests/scaphandre-mock.yaml` exposes a corresponding fictional process
per service so the sub-test 7 of `scaphandre-mock-validation` keeps passing.

## Network policies

The intra-shop NetworkPolicy in `manifests/network-policies.yaml` (rule
`shop-intra-namespace`) covers ports 8080-8094 for ingress between pods in
the `shop` namespace. Any pod arboring `app.kubernetes.io/part-of:
perf-sentinel-lab` inherits Postgres + OTel Collector egress for free.

No new NetworkPolicy needs to ship per stack as long as the port stays in
range and the label is set.

## Validation contract

Per-stack validation flow (run in sequence by the multistack harness):

1. `make seed-<stack>-svc` — builds the image, applies the Helm chart,
   waits for `Ready=True`.
2. `kubectl apply -f scenarios/<stack>-svc-validation-job.yaml` (or
   `bash scenarios/<stack>-svc-validation.js` driven by k6) — fires the 10
   fault endpoints under load.
3. `scripts/validate-findings-multistack.sh <stack>-svc` — polls
   `/api/findings` and asserts at least one finding per anti-pattern type
   with `service = <stack>-svc`.

Success criterion per stack: 10/10 PASS in
`tmp/validation-report-<stack>-svc.md`. The Java baseline
(`make validate-findings`) must keep returning 10/10 untouched (regression
guard).

End-to-end target after the 12 stacks are landed: **150 findings** total
(15 services × 10 anti-patterns) on the daemon `/api/findings`, with
non-regression on the Java baseline. See the plan file for details.

## Stack-specific release notes

Notes captured at planning time. Each section accumulates as the stack lands.

### Helidon 4.4.0 (2026-03-17)

Source: [Helidon 4.4.0 release announcement](https://medium.com/helidon/helidon-4-4-0-released-d10be2fb8039).
Key points for the phase 3 (Helidon MP) and phase 4 (Helidon SE) deliveries:

- **LTS confirmed**: Helidon 4.4 is now an LTS release covered by Oracle's
  Java Verified Portfolio (JVP). The lab pins 4.4.0 with confidence.
- **Tip and Tail model**: future Helidon releases adopt OpenJDK's
  Tip-and-Tail. Helidon 4.4 is the Tail (LTS), and the next major
  (Helidon 27) will track JDK 27 with the Tip cadence. Bumping the lab
  past 4.4 is a deliberate Sept-2026+ decision, not a routine patch.
- **Java 21 minimum, Java 25 recommended**: Helidon 4.4 runs on the same
  `gcr.io/distroless/java25-debian12` image the Java baseline uses.
- **OpenTelemetry exporter**: the upstream OTel release Helidon 4.4 ships
  with no longer includes the Jaeger exporter. Helidon's Jaeger tracing
  provider is deprecated. **Lab choice**: stick with OTLP HTTP/protobuf
  exporter (`http://otel-collector-opentelemetry-collector.observability...`),
  consistent with the contract documented above.
- **Metrics & logs over OTel**: Helidon 4.4 adds OTLP-exportable metrics
  and OTel-aligned logging. Lab only ships traces (`OTEL_METRICS_EXPORTER=none`,
  `OTEL_LOGS_EXPORTER=none`), so this is informational only.
- **CORS config moved**: feature-level CORS config is deprecated; the new
  centralized top-level config is preferred. Lab does not expose CORS, so
  this is informational only.
- **Helidon SE (phase 4)**: plain Java, no Jakarta APIs, minimal footprint.
  Routing via `WebServer` builder, DB access via Helidon DB Client (Vert.x).
  Style is imperative-by-default; the new declarative APIs in 4.4 are
  opt-in via code-generation (annotations like `@RestServer.Endpoint`,
  `@Http.Path`, `@Service.Singleton`, `@Metrics.Counted`).
- **Helidon MP (phase 3)**: MicroProfile 6.1 compliant. Jakarta JAX-RS +
  CDI + JPA stack, close to Quarkus in shape. Build with Maven, deploy
  the same distroless image, swap the Quarkus extensions for the
  MicroProfile equivalents. Declarative APIs share the same annotation
  set as SE.
- **Helidon JSON**: new build-time JSON library (3x faster than Jackson
  in upstream benchmarks). Optional for the lab. Default to Jackson for
  consistency with the Java baseline; switching to Helidon JSON is a
  follow-up if performance becomes a concern.
- **Database support**: Oracle Database 26ai added in 4.4. Lab uses
  Postgres exclusively, so no impact.

## Naming and layout reminders

Repository layout for each new stack lives under `services/<stack>-svc/`,
following the per-stack idiom (Maven, Cargo, npm, Python, Go). Each service
ships:

- its source tree
- its own `Dockerfile` (multistage, distroless or chiseled runtime)
- its own `helm/` chart (Deployment + Service + Secret +
  ServiceMonitor) mirroring the pattern in `services/order-service/helm/`
- its own `README.md` with quickstart + endpoint map
- a `scenarios/<stack>-svc-validation.js` k6 composite scenario (one per
  stack, hitting the 10 fault endpoints)
- an entry in `manifests/perf-sentinel-daemon.yaml` and
  `manifests/scaphandre-mock.yaml`
- an entry in `manifests/postgres-multistack-schemas.yaml`'s schema list

Do not introduce a monorepo build tool to "share" code between stacks. Each
service is intentionally autonomous so that one stack's churn never blocks
another.
