#!/usr/bin/env python3
"""Generate the two crafted OTLP/JSON corpora this scenario needs.

`cases` — one trace per broker family, 12 PRODUCER publishes each, so any
`n_plus_one_min_occurrences` up to 12 is cleared. Covers the destination
spellings a real fleet produces and the lab has no emitter for: a RabbitMQ
default exchange (blank `destination.name`), a Pulsar topic URL (a
scheme-carrying name that must NOT be rewritten), an AMQP connection URI
carrying credentials (which MUST lose them), an IBM MQ / JMS queue
(`ORDERS@QM1`, whose `@` must NOT be read as a userinfo delimiter), and a
RabbitMQ routing-key glob.

`shapes` — two traces identical except for the parent of the analyzable span,
isolating where the CONSUMER `receive` span sits relative to the work it
triggered. `a-sibling` is the shape the real OpenTelemetry demo capture emits
(see ../astronomy-shop/fixtures/); `b-ancestor` is the shape
`resolve_producer_link` walks for. Both carry the same span link.

Deterministic: fixed ids and timestamps, no clock and no randomness, so the
corpora are byte-stable across runs and a diff means a real edit.
"""
import json
import sys

# Fixed wall clock. Any constant works: nothing in the analyzed path is
# relative to "now" for batch `analyze --input`.
BASE_NS = 1783677955689000000
PRODUCER_TRACE = "61398e4b7d55f81867771ae8fd640579"

# id, messaging.system, messaging.destination.name, span name, per-occurrence extra
CASES = [
    ("c1-rabbit-named", "rabbitmq", "orders.exchange", "orders.exchange publish", None),
    ("c2-rabbit-default", "rabbitmq", "", "publish", "routing_key"),
    ("c3-pulsar-topic", "pulsar", "persistent://public/default/orders",
     "persistent://public/default/orders publish", None),
    ("c4-amqp-uri", "rabbitmq", "amqp://appuser:s3cr3t@rabbit:5672/orders", "publish", None),
    ("c5-ibmmq-jms", "jms", "ORDERS@QM1", "ORDERS@QM1 publish", None),
    ("c6-routing-glob", "rabbitmq", "logs.#", "logs.# publish", None),
]

# SpanKind, from the OTLP proto enum.
INTERNAL, SERVER, CLIENT, PRODUCER, CONSUMER = 1, 2, 3, 4, 5


def attr(key, value):
    return {"key": key, "value": {"stringValue": value}}


def span(trace, span_id, parent, name, kind, start_ns, dur_us, attrs=None, links=None):
    out = {
        "traceId": trace,
        "spanId": span_id,
        "parentSpanId": parent,
        "name": name,
        "kind": kind,
        "startTimeUnixNano": str(start_ns),
        "endTimeUnixNano": str(start_ns + dur_us * 1000),
        "attributes": attrs or [],
        "status": {},
    }
    if links:
        out["links"] = [{"traceId": t, "spanId": "aaaaaaaaaaaaaaaa"} for t in links]
    return out


def request(service, spans):
    return {"resourceSpans": [{
        "resource": {"attributes": [attr("service.name", service)]},
        "scopeSpans": [{"scope": {"name": "broker-cases"}, "spans": spans}],
    }]}


def build_cases():
    out = []
    for idx, (cid, system, dest, span_name, extra) in enumerate(CASES):
        trace = f"{idx + 1:032x}"
        root = f"{idx + 1:016x}"
        spans = [span(trace, root, "", "POST /checkout", SERVER, BASE_NS, 50_000,
                      [attr("http.request.method", "POST"), attr("http.route", "/checkout")])]
        for i in range(12):
            attrs = [attr("messaging.system", system), attr("messaging.operation", "publish")]
            if dest:
                attrs.append(attr("messaging.destination.name", dest))
            if extra == "routing_key":
                # A default exchange leaves destination.name blank: the real
                # target only lives in the routing key. Three distinct keys
                # here, so a template that ignores them is visible as a merge.
                attrs.append(attr("messaging.rabbitmq.destination.routing_key",
                                  f"logs.tenant{i % 3}"))
            spans.append(span(trace, f"{idx + 1:012x}{i:04x}", root, span_name, PRODUCER,
                              BASE_NS + 1000 + i * 2_000_000, 1500, attrs))
        out.append(request(f"probe-{cid}", spans))
    return out


def build_shapes():
    messaging = [attr("messaging.system", "kafka"),
                 attr("messaging.destination.name", "orders"),
                 attr("messaging.operation", "receive")]
    sql = [attr("db.system", "postgresql"),
           attr("db.statement", 'INSERT INTO accounting."order" (order_id) VALUES ($1)')]
    out = []
    for idx, (cid, sql_parent) in enumerate([("a-sibling", "root"), ("b-ancestor", "receive")]):
        trace = f"{idx + 11:032x}"
        root = f"{idx + 11:016x}"
        receive = f"{idx + 21:016x}"
        work = f"{idx + 31:016x}"
        spans = [
            span(trace, root, "", "order-consumed", INTERNAL, BASE_NS, 5000),
            span(trace, receive, root, "orders receive", CONSUMER, BASE_NS + 100, 800,
                 messaging, [PRODUCER_TRACE]),
            span(trace, work, root if sql_parent == "root" else receive,
                 "postgresql", CLIENT, BASE_NS + 1000, 1300, sql),
        ]
        out.append(request(f"accounting-{cid}", spans))
    return out


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("cases", "shapes"):
        sys.exit("usage: broker_cases.py {cases|shapes} <out.ndjson>")
    payload = build_cases() if sys.argv[1] == "cases" else build_shapes()
    with open(sys.argv[2], "w") as fh:
        for req in payload:
            fh.write(json.dumps(req) + "\n")
    print(f"{sys.argv[1]}: {len(payload)} traces -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
