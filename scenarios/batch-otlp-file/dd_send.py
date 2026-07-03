#!/usr/bin/env python3
# Send synthetic dd-trace APM traces (Datadog Agent v0.4 intake, msgpack) to
# the datadogreceiver, one HTTP PUT per trace so the file exporter writes one
# NDJSON line per intake (no batch processor in collector-ddtrace.yaml).
# Same span shape as scenarios/datadog-bridge/live/dd_send.py: a classic
# sequential SQL N+1, SQL pre-obfuscated (literals -> ?) as dd-trace ships it.
import os
import sys
import time
import urllib.request

import msgpack

PORT = int(os.environ.get("DD_PORT", "8126"))
COUNT = int(sys.argv[1]) if len(sys.argv) > 1 else 3
BASE = 1_749_297_600_000_000_000          # fixed ns (no wall-clock dependency)
OBF = "SELECT * FROM order_item WHERE order_id = ?"
UNIFORM = [5, 6, 4, 5, 6, 4]
SERVICE = "dd-shop"


def span(trace_id, span_id, parent_id, name, resource, typ, start_ns, dur_ms, meta=None):
    return {
        "trace_id": trace_id, "span_id": span_id, "parent_id": parent_id,
        "name": name, "resource": resource, "service": SERVICE, "type": typ,
        "start": start_ns, "duration": dur_ms * 1_000_000, "error": 0,
        "meta": meta or {}, "metrics": {},
    }


def build_trace(n):
    trace_id = 0xABCDEF10 + n
    spans = [span(trace_id, 1, 0, "rack.request", "GET /api/orders", "web", BASE, 200)]
    cur = BASE + 1_000_000
    for d in UNIFORM:
        spans.append(span(trace_id, len(spans) + 1, 1, "postgres.query", OBF, "sql",
                          cur, d, meta={"db.type": "postgres"}))
        cur += (d + 1) * 1_000_000
    return spans


def main():
    for n in range(COUNT):
        payload = msgpack.packb([build_trace(n)], use_bin_type=True)
        req = urllib.request.Request(
            f"http://localhost:{PORT}/v0.4/traces", data=payload,
            headers={"Content-Type": "application/msgpack",
                     "Datadog-Meta-Lang": "python",
                     "Datadog-Meta-Tracer-Version": "2.9.0",
                     "X-Datadog-Trace-Count": "1"},
            method="PUT")
        with urllib.request.urlopen(req, timeout=10) as r:
            print(f"v0.4/traces [{n + 1}/{COUNT}] ->", r.status)
        time.sleep(0.5)


if __name__ == "__main__":
    main()
