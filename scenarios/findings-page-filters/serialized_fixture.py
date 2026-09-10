#!/usr/bin/env python3
"""Emit a native-JSON trace of strictly sequential SQL calls with
production-sized templates, the shape a `serialized_calls` suggestion used
to carry whole.

tracegen has no `serialized` pattern and its templates are short, so neither
knob reaches the sentence this fixture exists to measure. One root HTTP span
and N SQL children, each starting after the previous one ends, so
`longest_non_overlapping` keeps them all, and each statement padded past the
120-character cut so the elision is observable.

Usage: serialized_fixture.py <out.json> [calls] [template_bytes]
"""

import json
import sys

CALLS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
TEMPLATE_BYTES = int(sys.argv[3]) if len(sys.argv) > 3 else 4096
BASE_MS = 0
CALL_MS = 5
ENDPOINT = "POST /api/orders/checkout"


def stamp(offset_ms):
    return "2026-09-10T12:00:%02d.%03dZ" % (offset_ms // 1000, offset_ms % 1000)


def padded_select(index):
    """A distinct wide select per call: distinct so the 3-template cut is
    what bounds the sentence, wide so the 120-character cut is too."""
    stmt = "SELECT t.id, t.label FROM table_%03d t WHERE t.id = %d" % (index, index)
    col = 0
    while len(stmt) < TEMPLATE_BYTES:
        stmt += " AND t.col_%04d = %d" % (col, col)
        col += 1
    return stmt


events = [
    {
        "timestamp": stamp(BASE_MS),
        "trace_id": "trace-serialized-1",
        "span_id": "span-root",
        "service": "checkout-svc",
        "type": "http_out",
        "operation": "POST",
        "target": "http://gateway/api/orders/checkout",
        "duration_us": (CALLS + 2) * CALL_MS * 1000,
        "source": {"endpoint": ENDPOINT, "method": "CheckoutService::submit"},
    }
]
for i in range(CALLS):
    start = BASE_MS + (i + 1) * CALL_MS
    events.append(
        {
            "timestamp": stamp(start),
            "trace_id": "trace-serialized-1",
            "span_id": "span-child-%d" % i,
            "parent_span_id": "span-root",
            "service": "checkout-svc",
            "type": "sql",
            "operation": "SELECT",
            "target": padded_select(i),
            # Ends one millisecond before the next one starts, so no two
            # children overlap and the whole block is one sequence.
            "duration_us": (CALL_MS - 1) * 1000,
            "source": {"endpoint": ENDPOINT, "method": "CheckoutService::submit"},
        }
    )

with open(sys.argv[1], "w") as stream:
    json.dump(events, stream)
print("%d calls, %d-byte templates -> %s" % (CALLS, TEMPLATE_BYTES, sys.argv[1]))
