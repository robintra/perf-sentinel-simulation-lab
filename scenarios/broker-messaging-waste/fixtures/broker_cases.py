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

`slow-cases` — one RabbitMQ trace with three deliberately slow PRODUCER sends,
which asserts the executable `slow_messaging` gate.

`shapes` — four traces isolating where the CONSUMER `receive` span sits relative
to the work it triggered, and which work it may explain. All carry the same span
link, and they differ only in topology, so a diverging verdict names the topology
rule that produced it.

- `a-sibling`   the shape the real capture emits: `receive` beside the work.
- `b-ancestor`  `receive` above the work.
- `c-nontriggered` a sibling that starts BEFORE the `receive`, beside one that
  starts after it. The earlier span cannot have been caused by the message, so it
  must NOT inherit the link; the later one must. A false link is worse than an
  absent one — it sends a reader to an unrelated upstream trace.
- `d-handler`   the work sits under an intermediate handler (`@Transactional`,
  or an agent `process` span) that is itself the sibling of the `receive`, so
  resolution has to retry at each level of the ancestor chain rather than only
  at the analyzable span's own.
- `e-early-handler` the handler started BEFORE the delivery and its I/O child
  after it. The guard has to judge the attributed node, not the leaf, so the
  handler shields its whole subtree.
- `f-two-receives` two deliveries under one parent: the work belongs to the last
  that arrived before it.

`shapes-reversed` re-emits `shapes` with every span array reversed and nothing
else changed, so comparing the two answers one question: does payload order
influence the resolved link? It must not.

These are **crafted probes, not corpus evidence.** None of `c-nontriggered`,
`d-handler`, `e-early-handler` or `f-two-receives` occurs anywhere in the
committed astronomy capture, so the real-emitter proof lives in the F1/F2 rates
measured on that capture, and the probes only answer "does the rule hold when the
shape does show up".

Deterministic: fixed ids and timestamps, no clock and no randomness, so the
corpora are byte-stable across runs and a diff means a real edit.
"""
import json
import sys

# Fixed wall clock. Any constant works: nothing in the analyzed path is
# relative to "now" for batch `analyze --input`.
BASE_NS = 1783677955689000000
PRODUCER_TRACE = "61398e4b7d55f81867771ae8fd640579"
# A second producer, so the two-receive case can name which one won.
PRODUCER_TRACE_2 = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"

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


def build_slow_cases():
    trace, root = f"{21:032x}", f"{21:016x}"
    attrs = [attr("messaging.system", "rabbitmq"),
             attr("messaging.destination.name", "probe.slow"),
             attr("messaging.operation.type", "send")]
    return [request("probe-slow-rabbitmq", [
        span(trace, root, "", "POST /api/fault/slow-messaging", SERVER, BASE_NS, 2_000_000),
        *[span(trace, f"{81 + i:016x}", root, "probe.slow send", PRODUCER,
               BASE_NS + 1_000 + i * 600_000_000, 600_000, attrs)
          for i in range(3)],
    ])]


MESSAGING = [attr("messaging.system", "kafka"),
             attr("messaging.destination.name", "orders"),
             attr("messaging.operation", "receive")]


def sql_attrs(table):
    return [attr("db.system", "postgresql"),
            attr("db.statement", f'INSERT INTO accounting."{table}" (id) VALUES ($1)')]


def build_shapes():
    out = []

    # a-sibling / b-ancestor: one analyzable span, differing only in its parent.
    for idx, (cid, sql_parent) in enumerate([("a-sibling", "root"), ("b-ancestor", "receive")]):
        trace = f"{idx + 11:032x}"
        root, receive, work = f"{idx + 11:016x}", f"{idx + 21:016x}", f"{idx + 31:016x}"
        out.append(request(f"accounting-{cid}", [
            span(trace, root, "", "order-consumed", INTERNAL, BASE_NS, 5000),
            span(trace, receive, root, "orders receive", CONSUMER, BASE_NS + 100, 800,
                 MESSAGING, [PRODUCER_TRACE]),
            span(trace, work, root if sql_parent == "root" else receive,
                 "postgresql", CLIENT, BASE_NS + 1000, 1300, sql_attrs("order")),
        ]))

    # c-nontriggered: two analyzable siblings, one starting before the receive
    # and one after. Only the later one may carry the link. The table names
    # differ so the two are distinguishable by template in the explain tree.
    trace, root = f"{13:032x}", f"{13:016x}"
    out.append(request("accounting-c-nontriggered", [
        span(trace, root, "", "order-consumed", INTERNAL, BASE_NS, 9000),
        # A periodic flush already in flight when the delivery landed.
        span(trace, f"{41:016x}", root, "postgresql", CLIENT, BASE_NS + 100, 700,
             sql_attrs("outbox_flush")),
        span(trace, f"{42:016x}", root, "orders receive", CONSUMER, BASE_NS + 2000, 800,
             MESSAGING, [PRODUCER_TRACE]),
        span(trace, f"{43:016x}", root, "postgresql", CLIENT, BASE_NS + 3000, 1300,
             sql_attrs("order")),
    ]))

    # d-handler: the work sits one level below an intermediate handler that is
    # itself the receive's sibling — the shape the Java agent emits around a
    # @Transactional boundary.
    trace, root = f"{14:032x}", f"{14:016x}"
    handler = f"{51:016x}"
    out.append(request("accounting-d-handler", [
        span(trace, root, "", "order-consumed", INTERNAL, BASE_NS, 9000),
        span(trace, f"{52:016x}", root, "orders receive", CONSUMER, BASE_NS + 100, 800,
             MESSAGING, [PRODUCER_TRACE]),
        span(trace, handler, root, "OrderHandler.onMessage", INTERNAL, BASE_NS + 1000, 6000),
        span(trace, f"{53:016x}", handler, "postgresql", CLIENT, BASE_NS + 2000, 1300,
             sql_attrs("order")),
    ]))

    # e-early-handler: the handler starts BEFORE the delivery, its I/O child
    # after it. The guard must judge the node whose subtree is attributed — the
    # handler — not the leaf, so a handler already running when the message
    # landed shields everything below it however late its own I/O fires.
    trace, root = f"{15:032x}", f"{15:016x}"
    handler = f"{61:016x}"
    out.append(request("accounting-e-early-handler", [
        span(trace, root, "", "order-consumed", INTERNAL, BASE_NS, 9000),
        span(trace, handler, root, "ScheduledFlush.run", INTERNAL, BASE_NS + 100, 8000),
        span(trace, f"{62:016x}", root, "orders receive", CONSUMER, BASE_NS + 2000, 800,
             MESSAGING, [PRODUCER_TRACE]),
        # Starts after the receive, but its parent did not: no link.
        span(trace, f"{63:016x}", handler, "postgresql", CLIENT, BASE_NS + 3000, 1300,
             sql_attrs("outbox_flush")),
    ]))

    # f-two-receives: a consumer loop handling two deliveries under one parent.
    # The work belongs to the LAST message that arrived before it, so the second
    # receive's producer wins — and which one wins must not depend on the order
    # the exporter serialised them in (see the `reversed` mode).
    trace, root = f"{16:032x}", f"{16:016x}"
    out.append(request("accounting-f-two-receives", [
        span(trace, root, "", "order-consumed", INTERNAL, BASE_NS, 9000),
        span(trace, f"{71:016x}", root, "orders receive", CONSUMER, BASE_NS + 1000, 500,
             MESSAGING, [PRODUCER_TRACE]),
        span(trace, f"{72:016x}", root, "orders receive", CONSUMER, BASE_NS + 2000, 500,
             MESSAGING, [PRODUCER_TRACE_2]),
        span(trace, f"{73:016x}", root, "postgresql", CLIENT, BASE_NS + 3000, 1300,
             sql_attrs("order")),
    ]))
    return out


def main():
    modes = ("cases", "slow-cases", "shapes", "shapes-reversed")
    if len(sys.argv) != 3 or sys.argv[1] not in modes:
        sys.exit(f"usage: broker_cases.py {{{'|'.join(modes)}}} <out.ndjson>")
    if sys.argv[1] == "cases":
        payload = build_cases()
    elif sys.argv[1] == "slow-cases":
        payload = build_slow_cases()
    else:
        payload = build_shapes()
        if sys.argv[1] == "shapes-reversed":
            # Same spans, same ids, same trace ids — only the order the exporter
            # serialised them in. Every resolved link must be identical to the
            # forward corpus: which receive explains a span is a question about
            # start times, and payload order must not answer it.
            for req in payload:
                for rs in req["resourceSpans"]:
                    for ss in rs["scopeSpans"]:
                        ss["spans"].reverse()
    with open(sys.argv[2], "w") as fh:
        for req in payload:
            fh.write(json.dumps(req) + "\n")
    print(f"{sys.argv[1]}: {len(payload)} traces -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
