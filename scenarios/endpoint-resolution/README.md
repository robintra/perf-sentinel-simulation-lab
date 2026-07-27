# endpoint-resolution

Pins how perf-sentinel resolves `source.endpoint` at OTLP ingestion, the field
that decides which findings share an acknowledgment.

**Prerequisites:** none beyond a local `perf-sentinel` release binary. No
cluster, no daemon, no Docker. Requires product **>= 0.9.22**.

```bash
make verify-endpoint-resolution
# or, against a specific build:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel ./scenarios/endpoint-resolution/verify.sh
```

## Why it exists

Product 0.9.22 replaced the direct-parent lookup with one bounded walk up the
parent chain (`CODE_ATTRS_MAX_DEPTH = 8`) that resolves, in order:

1. the nearest inbound HTTP route — `http.route` on any span kind, or
   `http.url` / `url.full` on any kind **except** CLIENT, blank values skipped;
2. otherwise the **outermost** usable `code.*` frame found along that walk;
3. otherwise the literal `"unknown"`.

The acknowledgment signature is `type : service : endpoint : hash(template)`.
Every rule above therefore decides which findings collide in that signature —
acknowledging one finding silently hides every other finding that resolves to
the same endpoint. That makes endpoint resolution an ack-correctness question,
not a display question, which is why it gets its own gate.

The product's own tests for this are hand-authored OTLP, Jaeger and Zipkin
fixtures. They encode assumptions about what real agents emit. That is the
0.9.9 failure mode, where a hand-written PHP fixture stayed green while the
feature was broken in-cluster — so the frames in `agent-frames.ndjson` are read
out of real agent output rather than invented (see Fixtures below).

## Assertions

`analyze --format json` runs once per fixture; each fixture trace produces
exactly one `n_plus_one_sql`, whose `source_endpoint` names the ancestor the
resolver picked.

### A — the ancestor walk

| id | assertion                                    | 0.9.22                  | 0.9.17 baseline                |
|----|----------------------------------------------|-------------------------|--------------------------------|
| A1 | route two levels above the leaf              | `/api/orders`           | `unknown`                      |
| A2 | a route outranks the code frames below it    | `/api/orders`           | `unknown`                      |
| A3 | a route at the depth bound is still found    | `/api/at-limit`         | `unknown`                      |
| A4 | a route past the depth bound is not          | `unknown`               | `unknown`                      |
| A5 | a blank `http.route` is skipped, not adopted | `com.shop.PurgeJob.run` | `'   '` (three literal spaces) |

A1 is the layout the 0.9.22 CHANGELOG names as the common case
(`tomcat -> hibernate -> jdbc`). A5 pins a real 0.9.17 defect: a whitespace-only
route became a whitespace-only endpoint.

### B — the CLIENT skip

| id | assertion                                               | 0.9.22          | 0.9.17 baseline                        |
|----|---------------------------------------------------------|-----------------|----------------------------------------|
| B1 | `url.full` on a CLIENT ancestor is not an inbound route | `unknown`       | `https://third-party.example/v1/rates` |
| B2 | `url.full` on a SERVER ancestor still counts            | the URL         | the URL                                |
| B3 | `url.full` on an unspecified kind still counts          | the URL         | the URL                                |
| B4 | a route above a CLIENT ancestor wins                    | `/api/checkout` | the third-party URL                    |
| B5 | `http.route` counts on any kind, CLIENT included        | `/api/orders`   | `/api/orders`                          |

B1 and B4 are the fix: before, an outbound call's URL up to eight levels away
could name the finding, attributing it to a third party. B2 and B3 pin the
other side — the guard must not swallow legitimate inbound fallbacks, and
manual or legacy instrumentation that leaves the kind unspecified stays
eligible.

### C — outermost, not nearest

| id    | assertion                                                | 0.9.22                                                                      |
|-------|----------------------------------------------------------|-----------------------------------------------------------------------------|
| C1/C2 | each entry point names itself, not the DAO they share    | `com.shop.OrderService.listOrders` / `com.shop.ReportService.monthlyReport` |
| C3    | two entry points over one statement stay distinct        | true                                                                        |
| C4    | a framework frame above the entry point is skipped       | `com.shop.OrderService.listOrders`                                          |
| C5    | two entry points under one framework layer stay distinct | true                                                                        |

C1–C3 are the point of keeping the outermost frame rather than the nearest: the
nearest is the DAO every caller shares, which collides in the ack signature
exactly as `"unknown"` did.

**C4 and C5 pin the framework-frame rule.** "Outermost" means the outermost
usable *application* frame. A framework layer carrying `code.*` of its own is
skipped, so the entry point below it names the finding and two entry points
under one framework layer stay distinct.

That rule exists because of a measured collapse: before it, every code-frame
endpoint on the two PHP stacks resolved to a single framework kernel — 1799
`symfony-svc` findings on `Symfony\Component\HttpKernel\HttpKernel::handle`
and 1617 `laravel-svc` findings on `Illuminate\Foundation\Http\Kernel::handle`.
An endpoint that looks resolved while colliding in the ack signature exactly as
`"unknown"` did is worse than `"unknown"`, because nothing signals it.

### D — code-frame spelling

D1–D9 assert that one origin spells one endpoint whichever attributes the agent
emits: the legacy `code.namespace` + `code.function` pair, or the stable
`code.function.name`. A difference re-keys every acknowledgment recorded against
that frame the day the agent is upgraded.

D10–D15 assert the frames the resolver must refuse rather than mangle:
`strip_endpoint_secrets` truncates an endpoint at `?` and strips userinfo before
the first `/`, so an accepted `Order.valid?` would reach the ack signature as
`Order.valid` and silently share it with the real `Order.valid`. `#` is
rewritten to `.` for the same reason, and a bare unqualified name like `execute`
is refused because it collides exactly as `"unknown"` did.

### E — framework frames name no origin

E1-E7 assert that a framework frame is refused rather than adopted: the Symfony
and Laravel HTTP kernels, Doctrine's DBAL statement, `PDOStatement`, Spring's
`DispatcherServlet`, Slim's `App` and the PHP-DI controller invoker.

E8-E10 assert the list matches on a **prefix**, never a substring. Three
application-owned frames that merely resemble a framework namespace must
survive: `com.myshop.springboard.OrderJob.run`,
`com.apachecorp.billing.Invoicer.emit` and
`IlluminateMetrics\Collector::gather`. A substring match would swallow all
three, which is the failure mode a rejection list invites.

### Discrimination

39/39 on the fixed branch, 23/39 on 0.9.17.

## Fixtures

`fixtures/generate.py` regenerates both files (stdlib only, deterministic).

`ancestor-shapes.ndjson` — one trace per resolution rule, each a chain of
ancestors above eight identical-template SQL children. The chains are synthetic
on purpose: each isolates a single rule, and no real agent emits every layout on
demand.

`agent-frames.ndjson` — the spelling matrix. Every frame string is real:

| frame                                                            | source                                                                                                       |
|------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| `Slim\App::handle`, `DI\Bridge\Slim\ControllerInvoker::__invoke` | `scenarios/astronomy-shop/fixtures/degraded-slice.ndjson`, the `quote` service (PHP OTel SDK, Slim + PHP-DI) |
| `oteldemo.AdService` + `getAdsByCategory`                        | the same slice, the `ad` service (Java)                                                                      |
| `com.perfsim.order.job.ScheduledJobs` + `reconcileOrders`        | this lab's `order-service` under the OTel javaagent, captured from the Collector file exporter               |
| Go, .NET, Python, Node, Rust rows                                | each ecosystem's documented qualified-name spelling                                                          |
