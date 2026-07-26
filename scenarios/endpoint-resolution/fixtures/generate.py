#!/usr/bin/env python3
# Generate the OTLP/JSON fixtures for the endpoint-resolution scenario
# (product 0.9.22 `source.endpoint` ancestor walk + code-frame fallback).
#
# Two files, each OTLP/JSON NDJSON (one ExportTraceServiceRequest per line),
# the shape `analyze --input` auto-detects and the shape the Collector `file`
# exporter writes. The OTLP path is the only one with a parent walk, which is
# exactly what these fixtures exercise. No cluster, no daemon.
#
#   ancestor-shapes.ndjson
#     One trace per resolution rule. Each trace is a chain of ancestors above
#     eight identical-template SQL children, so exactly one n_plus_one_sql
#     fires per trace and its source_endpoint names the ancestor the resolver
#     picked. The chains are synthetic ON PURPOSE: each isolates one rule, and
#     no real agent emits every layout on demand.
#
#   agent-frames.ndjson
#     The code-frame spelling matrix. Every frame string here was READ OUT OF
#     REAL AGENT OUTPUT, not invented:
#       - PHP  `Slim\\App::handle`, `DI\\Bridge\\Slim\\ControllerInvoker::__invoke`
#              from scenarios/astronomy-shop/fixtures/degraded-slice.ndjson
#              (the `quote` service, PHP OTel SDK on Slim + PHP-DI)
#       - Java `oteldemo.AdService` + `getAdsByCategory` from the same slice,
#              and `com.perfsim.order.job.ScheduledJobs` + `reconcileOrders`
#              from this lab's order-service under the OTel javaagent
#       - the Go / .NET / Python / Node / Rust rows carry each ecosystem's
#              documented qualified-name spelling
#     Each origin appears twice: once as the legacy `code.namespace` +
#     `code.function` pair, once as the stable `code.function.name`. Both must
#     resolve to the same endpoint string, or an agent upgrade re-keys every
#     acknowledgment recorded against that frame.
import json
import os

BASE_NS = 1_780_000_000_000_000_000
INTERNAL, SERVER, CLIENT, UNSPEC = 1, 2, 3, 0
OUT_DIR = os.path.dirname(os.path.abspath(__file__))


def attr(key, value):
    return {"key": key, "value": {"stringValue": value}}


def sql_children(trace_id, parent_id, t0, first_span_num, count=8):
    """N identical-template reads: one n_plus_one_sql group per trace."""
    out = []
    for i in range(count):
        start = t0 + 10_000_000 + i * 20_000_000
        out.append({
            "traceId": trace_id, "spanId": f"{first_span_num + i:016x}",
            "parentSpanId": parent_id, "name": "SELECT items", "kind": CLIENT,
            "startTimeUnixNano": str(start),
            "endTimeUnixNano": str(start + 3_000_000 + i * 400_000),
            "attributes": [
                attr("db.system", "postgresql"),
                attr("db.statement", f"SELECT * FROM items WHERE id = {i + 1}")],
            "status": {},
        })
    return out


def trace(index, service, layers):
    """One resourceSpans document: `layers` outermost-first, then SQL leaves."""
    trace_id = f"{index + 1:032x}"
    t0 = BASE_NS + index * 20_000_000_000
    spans, parent = [], None
    for depth, (kind, attributes) in enumerate(layers):
        span_id = f"{(index + 1) * 1000 + depth:016x}"
        span = {
            "traceId": trace_id, "spanId": span_id, "name": f"L{depth}",
            "kind": kind, "startTimeUnixNano": str(t0),
            "endTimeUnixNano": str(t0 + 900_000_000),
            "attributes": [attr(k, v) for k, v in attributes.items()],
            "status": {},
        }
        if parent:
            span["parentSpanId"] = parent
        spans.append(span)
        parent = span_id
    spans += sql_children(trace_id, parent, t0, (index + 1) * 1000 + 100)
    return {"resourceSpans": [{
        "resource": {"attributes": [attr("service.name", service)]},
        "scopeSpans": [{"scope": {"name": "endpoint-resolution"}, "spans": spans}],
    }]}


TOMCAT = (INTERNAL, {"code.namespace": "org.apache.catalina.core.StandardWrapper",
                     "code.function": "invoke"})
ORDER_SVC = (INTERNAL, {"code.namespace": "com.shop.OrderService",
                        "code.function": "listOrders"})
REPORT_SVC = (INTERNAL, {"code.namespace": "com.shop.ReportService",
                         "code.function": "monthlyReport"})
SHARED_DAO = (INTERNAL, {"code.namespace": "com.shop.OrderDao",
                         "code.function": "findAll"})

# name -> ancestor chain, outermost first
SHAPES = {
    # A. the inbound route, found by walking rather than reading the direct parent
    "route-two-levels-up": [(SERVER, {"http.route": "/api/orders"}), ORDER_SVC],
    "route-above-frames": [(SERVER, {"http.route": "/api/orders"}),
                           ORDER_SVC, SHARED_DAO],
    "route-at-depth-limit": ([(SERVER, {"http.route": "/api/at-limit"})]
                             + [(INTERNAL, {})] * 7),
    "route-past-depth-limit": ([(SERVER, {"http.route": "/api/too-deep"})]
                               + [(INTERNAL, {})] * 10),
    "blank-route-then-frame": [(INTERNAL, {"code.namespace": "com.shop.PurgeJob",
                                           "code.function": "run"}),
                               (SERVER, {"http.route": "   "})],
    # B. an outbound call is not an inbound route
    "client-url-ancestor": [(CLIENT, {"url.full": "https://third-party.example/v1/rates"})],
    "server-url-ancestor": [(SERVER, {"url.full": "https://shop.example/api/orders"})],
    "unspecified-url-ancestor": [(UNSPEC, {"url.full": "https://shop.example/api/orders"})],
    "client-below-route": [(SERVER, {"http.route": "/api/checkout"}),
                           (CLIENT, {"url.full": "https://third-party.example/v1/rates"})],
    "route-on-client-span": [(CLIENT, {"http.route": "/api/orders"})],
    # C. outermost, not nearest -- and what that costs when a framework layer
    #    carries code.* of its own
    "framework-above-entry-a": [TOMCAT, ORDER_SVC, SHARED_DAO],
    "framework-above-entry-b": [TOMCAT, REPORT_SVC, SHARED_DAO],
    "app-entry-a": [ORDER_SVC, SHARED_DAO],
    "app-entry-b": [REPORT_SVC, SHARED_DAO],
}

# name -> code attributes on a single entry-point span carrying no HTTP attribute
FRAMES = {
    # PHP: real frames, both spellings of one origin
    "php-slim-stable": {"code.function.name": "Slim\\App::handle"},
    "php-slim-legacy": {"code.namespace": "Slim\\App", "code.function": "handle"},
    "php-invoker-stable": {
        "code.function.name": "DI\\Bridge\\Slim\\ControllerInvoker::__invoke"},
    "php-invoker-legacy": {"code.namespace": "DI\\Bridge\\Slim\\ControllerInvoker",
                           "code.function": "__invoke"},
    # Java: astronomy `ad`, and this lab's scheduled job
    "java-ad-legacy": {"code.namespace": "oteldemo.AdService",
                       "code.function": "getAdsByCategory"},
    "java-ad-stable": {"code.function.name": "oteldemo.AdService.getAdsByCategory"},
    "java-job-legacy": {"code.namespace": "com.perfsim.order.job.ScheduledJobs",
                        "code.function": "reconcileOrders"},
    "java-job-stable": {
        "code.function.name": "com.perfsim.order.job.ScheduledJobs.reconcileOrders"},
    # the ecosystems the branch assumed were dot-separated
    "rust-legacy": {"code.namespace": "myapp::worker", "code.function": "run"},
    "rust-stable": {"code.function.name": "myapp::worker::run"},
    "go-legacy": {"code.namespace": "github.com/shop/orders",
                  "code.function": "(*Repo).FindAll"},
    "go-stable": {"code.function.name": "github.com/shop/orders.(*Repo).FindAll"},
    "dotnet-legacy": {"code.namespace": "Shop.Orders.OrderRepository",
                      "code.function": "FindAll"},
    "dotnet-stable": {"code.function.name": "Shop.Orders.OrderRepository.FindAll"},
    "python-legacy": {"code.namespace": "shop.orders.repo", "code.function": "find_all"},
    "python-stable": {"code.function.name": "shop.orders.repo.find_all"},
    "node-legacy": {"code.namespace": "OrderRepository", "code.function": "findAll"},
    "node-stable": {"code.function.name": "OrderRepository.findAll"},
    # frames the resolver must refuse rather than mangle
    "ruby-predicate": {"code.namespace": "Order", "code.function": "valid?"},
    "ruby-plain": {"code.namespace": "Order", "code.function": "valid"},
    "php-anonymous-class": {"code.namespace": "App\\Jobs",
                            "code.function": "class@anonymous"},
    "hash-qualified": {"code.function.name": "MyClass#method"},
    "bare-function": {"code.function": "execute"},
    "blank-namespace": {"code.namespace": "   ", "code.function": "execute"},
}


def write(path, docs):
    with open(path, "w", encoding="utf-8") as fh:
        for doc in docs:
            fh.write(json.dumps(doc) + "\n")
    print(f"wrote {len(docs)} traces to {path}")


def main():
    write(os.path.join(OUT_DIR, "ancestor-shapes.ndjson"),
          [trace(i, f"shape-{name}", layers)
           for i, (name, layers) in enumerate(SHAPES.items())])
    write(os.path.join(OUT_DIR, "agent-frames.ndjson"),
          [trace(100 + i, f"frame-{name}", [(INTERNAL, attrs)])
           for i, (name, attrs) in enumerate(FRAMES.items())])


if __name__ == "__main__":
    main()
