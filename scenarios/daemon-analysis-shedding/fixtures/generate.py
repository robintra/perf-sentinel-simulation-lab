#!/usr/bin/env python3
# Generate shed-load.pb: the OTLP/protobuf payload replayed by verify.sh to
# overload the 0.8.6 analysis worker and force metered load-shedding.
#
# Why this exact shape:
#   - perf-sentinel's OTLP HTTP receiver accepts ONLY application/x-protobuf,
#     and its ingest parser KEEPS a span only if it is an I/O operation, i.e.
#     it carries db.statement / db.query.text (SQL) or http.url / url.full
#     (HTTP). A span with neither is dropped (crates/.../ingest/otlp.rs:290).
#     telemetrygen's generic spans have no I/O attributes, so they ingest as
#     zero events -- which is why this scenario hand-builds a payload instead.
#   - The analysis worker is fast: trivial single-span traces are scored in
#     microseconds, so they never back the bounded queue up. Each trace here
#     is therefore a realistic N+1: one HTTP SERVER root plus six SQL CLIENT
#     children sharing one template but differing in their bound id literal,
#     which makes detect+score do real per-trace work.
#   - PAYLOAD_TRACES distinct trace ids per request, replayed concurrently
#     against a daemon scoped to max_active_traces=20 + analysis_queue_capacity=1,
#     overflow the tiny window on every request (a ~280-trace eviction batch)
#     faster than the single worker drains them -> whole batches are shed.
#   - All traces share one service + template, so their findings collapse to a
#     single signature: the findings store stays tiny and the daemon does not
#     OOM under the flood.
#
# Regenerating needs the opentelemetry-proto package (pip install
# opentelemetry-proto). verify.sh never runs this; it replays the committed
# shed-load.pb with curl. Span clocks are irrelevant: the daemon keys its
# streaming-window TTL on span ARRIVAL time, not on the span clock.
import os

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

HERE = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_TRACES = 300
BASE_NS = 1_749_297_600_000_000_000


def kv(key, val):
    return common.KeyValue(key=key, value=common.AnyValue(string_value=val))


def build(n_traces):
    spans = []
    for i in range(1, n_traces + 1):
        trace_id = i.to_bytes(16, "big")
        root_id = (i * 8).to_bytes(8, "big")
        spans.append(
            trace.Span(
                trace_id=trace_id,
                span_id=root_id,
                name="GET /shed",
                kind=trace.Span.SPAN_KIND_SERVER,
                start_time_unix_nano=BASE_NS,
                end_time_unix_nano=BASE_NS + 200_000_000,
                attributes=[kv("http.route", "/shed"), kv("http.url", "http://shed/%d" % i)],
            )
        )
        for c in range(1, 7):  # six distinct id literals -> N+1, real scoring work
            start = BASE_NS + c * 10_000_000
            spans.append(
                trace.Span(
                    trace_id=trace_id,
                    span_id=(i * 8 + c).to_bytes(8, "big"),
                    parent_span_id=root_id,
                    name="SELECT shed_t",
                    kind=trace.Span.SPAN_KIND_CLIENT,
                    start_time_unix_nano=start,
                    end_time_unix_nano=start + 5_000_000,
                    attributes=[
                        kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM shed_t WHERE id = %d" % c),
                    ],
                )
            )
    req = svc.ExportTraceServiceRequest(
        resource_spans=[
            trace.ResourceSpans(
                resource=resource.Resource(attributes=[kv("service.name", "shed-load-svc")]),
                scope_spans=[
                    trace.ScopeSpans(
                        scope=common.InstrumentationScope(name="analysis-shedding-load", version="1.0"),
                        spans=spans,
                    )
                ],
            )
        ]
    )
    return req.SerializeToString()


def main():
    data = build(PAYLOAD_TRACES)
    path = os.path.join(HERE, "shed-load.pb")
    with open(path, "wb") as fh:
        fh.write(data)
    print("shed-load.pb  %d bytes  %d traces x 7 spans" % (len(data), PAYLOAD_TRACES))


if __name__ == "__main__":
    main()
