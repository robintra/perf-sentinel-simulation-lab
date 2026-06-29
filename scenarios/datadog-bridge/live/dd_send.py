#!/usr/bin/env python3
# Send a synthetic dd-trace APM trace (Datadog Agent v0.4 intake, msgpack) for
# the optional live leg: a classic sequential SQL N+1, SQL already obfuscated
# (literals -> ?), exactly as dd-trace ships it. The OTel Collector
# datadogreceiver converts it to OTLP (scope "Datadog", engine under
# db.system.name) and forwards it to the perf-sentinel daemon.
import urllib.request

import msgpack

BASE = 1_749_297_600_000_000_000          # fixed ns (no wall-clock dependency)
OBF = "SELECT * FROM order_item WHERE order_id = ?"
UNIFORM = [5, 6, 4, 5, 6, 4]
TRACE_ID = 0xABCDEF01
SERVICE = "dd-shop"


def span(span_id, parent_id, name, resource, typ, start_ns, dur_ms, meta=None):
    return {
        "trace_id": TRACE_ID, "span_id": span_id, "parent_id": parent_id,
        "name": name, "resource": resource, "service": SERVICE, "type": typ,
        "start": start_ns, "duration": dur_ms * 1_000_000, "error": 0,
        "meta": meta or {}, "metrics": {},
    }


def build_trace():
    spans = [span(1, 0, "rack.request", "GET /api/orders", "web", BASE, 200)]
    cur = BASE + 1_000_000
    for d in UNIFORM:
        spans.append(span(len(spans) + 1, 1, "postgres.query", OBF, "sql", cur, d,
                          meta={"db.type": "postgres"}))
        cur += (d + 1) * 1_000_000
    return spans


def main():
    payload = msgpack.packb([build_trace()], use_bin_type=True)
    req = urllib.request.Request(
        "http://localhost:8126/v0.4/traces", data=payload,
        headers={"Content-Type": "application/msgpack",
                 "Datadog-Meta-Lang": "python",
                 "Datadog-Meta-Tracer-Version": "2.9.0",
                 "X-Datadog-Trace-Count": "1"},
        method="PUT")
    with urllib.request.urlopen(req, timeout=10) as r:
        print("v0.4/traces ->", r.status)


if __name__ == "__main__":
    main()
