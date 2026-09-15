# endpoint-resolution

Pins how perf-sentinel resolves `source.endpoint` at OTLP ingestion, the field
that decides which findings share an acknowledgment.

**Prerequisites:** none beyond a local `perf-sentinel` release binary. No
cluster, no daemon, no Docker. Requires product **>= 0.9.22**, and
**>= 0.22.2** for family F.

```bash
make verify-endpoint-resolution
# or, against a specific build:
PERF_SENTINEL_LOCAL_BIN=/path/to/perf-sentinel ./scenarios/endpoint-resolution/verify.sh
```

## Why it exists

Product 0.9.22 replaced the direct-parent lookup with one bounded walk up the
parent chain (`CODE_ATTRS_MAX_DEPTH = 8`) that resolves, in order:

1. the nearest inbound HTTP route: `http.route` on any span kind, or
   `http.url` / `url.full` on any kind **except** CLIENT, blank values
   skipped.
2. otherwise the **outermost** usable `code.*` frame found along that walk.
3. otherwise the nearest CONSUMER span's `<messaging.system> <destination>`
   (since 0.22.2).
4. otherwise the literal `"unknown"`.

The acknowledgment signature is
`type : service : endpoint : hash(template)`. Every rule above therefore
decides which findings collide in that signature. Acknowledging one finding
silently hides every other finding that resolves to the same endpoint. That
makes endpoint resolution an ack-correctness question, not a display
question, which is why it gets its own gate.

The product's own tests for this are hand-authored OTLP, Jaeger and Zipkin
fixtures. They encode assumptions about what real agents emit. That is the
0.9.9 failure mode, where a hand-written PHP fixture stayed green while the
feature was broken in-cluster. The frames in `agent-frames.ndjson` are
therefore read out of real agent output rather than invented (see Fixtures
below).

## Assertions

`analyze --format json` runs once per fixture. Each fixture trace produces
exactly one `n_plus_one_sql`, whose `source_endpoint` names the ancestor
the resolver picked.

### A: the ancestor walk

| id | assertion                                               | 0.9.22          | 0.9.17 baseline                        |
|----|----------------------------------------------|-------------------------|--------------------------------|
| A1 | route two levels above the leaf              | `/api/orders`           | `unknown`                      |
| A2 | a route outranks the code frames below it    | `/api/orders`           | `unknown`                      |
| A3 | a route at the depth bound is still found    | `/api/at-limit`         | `unknown`                      |
| A4 | a route past the depth bound is not          | `unknown`               | `unknown`                      |
| A5 | a blank `http.route` is skipped, not adopted | `com.shop.PurgeJob.run` | `'   '` (three literal spaces) |

A1 is the layout the 0.9.22 CHANGELOG names as the common case
(`tomcat -> hibernate -> jdbc`). A5 pins a real 0.9.17 defect: a whitespace-only
route became a whitespace-only endpoint.

### B: the CLIENT skip

| id | assertion                                               | 0.9.22          | 0.9.17 baseline                        |
|----|---------------------------------------------------------|-----------------|----------------------------------------|
| B1 | `url.full` on a CLIENT ancestor is not an inbound route | `unknown`       | `https://third-party.example/v1/rates` |
| B2 | `url.full` on a SERVER ancestor still counts            | the URL         | the URL                                |
| B3 | `url.full` on an unspecified kind still counts          | the URL         | the URL                                |
| B4 | a route above a CLIENT ancestor wins                    | `/api/checkout` | the third-party URL                    |
| B5 | `http.route` counts on any kind, CLIENT included        | `/api/orders`   | `/api/orders`                          |

B1 and B4 are the fix: before, an outbound call's URL up to eight levels
away could name the finding, attributing it to a third party. B2 and B3 pin
the other side. The guard must not swallow legitimate inbound fallbacks,
and manual or legacy instrumentation that leaves the kind unspecified stays
eligible.

### C: outermost, not nearest

| id    | assertion                                                | 0.9.22                                                                      |
|-------|----------------------------------------------------------|-----------------------------------------------------------------------------|
| C1/C2 | each entry point names itself, not the DAO they share    | `com.shop.OrderService.listOrders` / `com.shop.ReportService.monthlyReport` |
| C3    | two entry points over one statement stay distinct        | true                                                                        |
| C4    | a framework frame above the entry point is skipped       | `com.shop.OrderService.listOrders`                                          |
| C5    | two entry points under one framework layer stay distinct | true                                                                        |

C1-C3 are the point of keeping the outermost frame rather than the nearest:
the nearest is the DAO every caller shares, which collides in the ack
signature exactly as `"unknown"` did.

**C4 and C5 pin the framework-frame rule.** "Outermost" means the outermost
usable *application* frame. A framework layer carrying `code.*` of its own is
skipped, so the entry point below it names the finding and two entry points
under one framework layer stay distinct.

That rule exists because of a measured collapse. Before it, every
code-frame endpoint on the two PHP stacks resolved to a single framework
kernel: 1799 `symfony-svc` findings on
`Symfony\Component\HttpKernel\HttpKernel::handle` and 1617 `laravel-svc`
findings on `Illuminate\Foundation\Http\Kernel::handle`. An endpoint that
looks resolved while colliding in the ack signature exactly as `"unknown"`
did is worse than `"unknown"`, because nothing signals it.

### D: code-frame spelling

D1-D9 assert that one origin spells one endpoint whichever attributes the
agent emits: the legacy `code.namespace` + `code.function` pair, or the
stable `code.function.name`. A difference re-keys every acknowledgment
recorded against that frame the day the agent is upgraded.

D10-D15 assert the frames the resolver must refuse rather than mangle:
`strip_endpoint_secrets` truncates an endpoint at `?` and strips userinfo
before the first `/`, so an accepted `Order.valid?` would reach the ack
signature as `Order.valid` and silently share it with the real
`Order.valid`. `#` is rewritten to `.` for the same reason, and a bare
unqualified name like `execute` is refused because it collides exactly as
`"unknown"` did.

### E: framework frames name no origin

E1-E7 assert that a framework frame is refused rather than adopted: the Symfony
and Laravel HTTP kernels, Doctrine's DBAL statement, `PDOStatement`, Spring's
`DispatcherServlet`, Slim's `App` and the PHP-DI controller invoker.

E8-E10 assert the list matches on a **prefix**, never a substring. Three
application-owned frames that merely resemble a framework namespace must
survive: `com.myshop.springboard.OrderJob.run`,
`com.apachecorp.billing.Invoicer.emit` and
`IlluminateMetrics\Collector::gather`. A substring match would swallow all
three, which is the failure mode a rejection list invites.

### F: the consumer destination

| id     | assertion                                                           | 0.22.2                               | 0.22.1 baseline |
|--------|---------------------------------------------------------------------|--------------------------------------|-----------------|
| F1     | a CONSUMER root names its rabbitmq destination                      | `rabbitmq crm.dossiers`              | `unknown`       |
| F2     | `messaging.destination.template` beats the name                     | `rabbitmq crm.{region}`              | `unknown`       |
| F3     | the legacy `messaging.destination` key resolves                     | `rabbitmq legacy.queue`              | `unknown`       |
| F4     | nested consumers, the nearest wins                                  | `rabbitmq crm.dossiers`              | `unknown`       |
| F5     | a route above the consumer wins                                     | `/api/import`                        | same            |
| F6     | a code frame between consumer and I/O wins                          | `com.shop.DossierListener.onDossier` | same            |
| F7-F11 | temporary (bool), temporary ("true"), `amq.gen-*`, `<default>`, `?` | `unknown`                            | same            |
| F12    | `messaging.system` is lowercased                                    | `rabbitmq crm.dossiers`              | `unknown`       |
| F13    | a kafka template keeps its placeholder                              | `kafka orders.{tenant}`              | `unknown`       |
| F14    | a PRODUCER root is not an entry point                               | `unknown`                            | same            |

F1 is the layout the Java agent's spring-rabbit instrumentation emits (the
CONSUMER span is the trace root on the consumer side, the repository call sits
beside the I/O). F4 is what amqp-client plus spring-rabbit emit together. F5
and F6 pin the rank: the destination only names what would otherwise be
`"unknown"`. F7 to F11 pin the refusals, since an accepted `orders?v2` would
reach the acknowledgment signature as `orders`. F14 pins that this lab's
eighteen producers keep `"unknown"` until a consumer exists (see
`consumer-endpoint`).

### Discrimination

53/53 on the fixed branch, 47/53 on 0.22.1, 23/39 on 0.9.17 for A to E.

## Fixtures

`fixtures/generate.py` regenerates both files (stdlib only, deterministic).

`ancestor-shapes.ndjson` holds one trace per resolution rule, each a chain
of ancestors above eight identical-template SQL children. The chains are
synthetic on purpose: each isolates a single rule, and no real agent emits
every layout on demand.

`agent-frames.ndjson` is the spelling matrix. Every frame string is real:

| frame                                                            | source                                                                                                       |
|------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| `Slim\App::handle`, `DI\Bridge\Slim\ControllerInvoker::__invoke` | `scenarios/astronomy-shop/fixtures/degraded-slice.ndjson`, the `quote` service (PHP OTel SDK, Slim + PHP-DI) |
| `oteldemo.AdService` + `getAdsByCategory`                        | the same slice, the `ad` service (Java)                                                                      |
| `com.perfsim.order.job.ScheduledJobs` + `reconcileOrders`        | this lab's `order-service` under the OTel javaagent, captured from the Collector file exporter               |
| Go, .NET, Python, Node, Rust rows                                | each ecosystem's documented qualified-name spelling                                                          |
