#!/usr/bin/env python3
# Generate mixed.pb: the OTLP/protobuf payload for the daemon (3rd ingestion
# path) leg of the non-sql-datastore-drop scenario.
#
# Same content as the Jaeger/Zipkin fixtures (see generate.py): one trace with
# an HTTP root, a 6-occurrence PostgreSQL N+1, 6 Redis spans, and one
# Elasticsearch span carrying BOTH db.statement AND url.full. The 0.9.2 drop
# on db.system must:
#   - remove the 6 Redis spans before any SQL tokenizer runs,
#   - remove the Elasticsearch span WITHOUT reclassifying it as an HTTP finding
#     (the edge case the task wants checked first on the OTLP path),
#   - keep only the HTTP root + 6 PostgreSQL spans -> a single n_plus_one_sql.
#
# perf-sentinel's OTLP HTTP receiver accepts ONLY application/x-protobuf, so
# the scope is forced through a real protobuf payload. Regenerating needs
# `pip install opentelemetry-proto`. verify.sh replays the committed mixed.pb
# with curl and never runs this.
import os

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NS = 1_749_297_600_000_000_000


def kv(key, val):
    return common.KeyValue(key=key, value=common.AnyValue(string_value=val))


def build():
    trace_id = (0xC0).to_bytes(16, "big")
    root_id = (1).to_bytes(8, "big")
    spans = [
        trace.Span(
            trace_id=trace_id,
            span_id=root_id,
            name="GET /api/orders",
            kind=trace.Span.SPAN_KIND_SERVER,
            start_time_unix_nano=BASE_NS,
            end_time_unix_nano=BASE_NS + 120_000_000,
            attributes=[kv("http.route", "/api/orders"), kv("url.full", "http://gw/api/orders")],
        )
    ]
    sid = 2
    # 6 PostgreSQL N+1 (the survivor)
    for i in range(1, 7):
        start = BASE_NS + sid * 1_000_000
        spans.append(trace.Span(
            trace_id=trace_id, span_id=sid.to_bytes(8, "big"), parent_span_id=root_id,
            name="db-query", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + 2_000_000,
            attributes=[kv("db.system", "postgresql"),
                        kv("db.statement", "SELECT * FROM orders WHERE id = %d" % i)],
        ))
        sid += 1
    # 6 Redis (dropped on db.system)
    for i in range(1, 7):
        start = BASE_NS + sid * 1_000_000
        spans.append(trace.Span(
            trace_id=trace_id, span_id=sid.to_bytes(8, "big"), parent_span_id=root_id,
            name="redis-GET", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=start, end_time_unix_nano=start + 800_000,
            attributes=[kv("db.system", "redis"), kv("db.statement", "GET user:%d" % i)],
        ))
        sid += 1
    # 1 Elasticsearch carrying db.statement AND url.full (dropped, NOT HTTP)
    start = BASE_NS + sid * 1_000_000
    spans.append(trace.Span(
        trace_id=trace_id, span_id=sid.to_bytes(8, "big"), parent_span_id=root_id,
        name="es-search", kind=trace.Span.SPAN_KIND_CLIENT,
        start_time_unix_nano=start, end_time_unix_nano=start + 5_000_000,
        attributes=[kv("db.system", "elasticsearch"),
                    kv("db.statement", "GET /orders/_search"),
                    kv("url.full", "http://es:9200/orders/_search")],
    ))

    req = svc.ExportTraceServiceRequest(resource_spans=[
        trace.ResourceSpans(
            resource=resource.Resource(attributes=[kv("service.name", "shop-mixed")]),
            scope_spans=[trace.ScopeSpans(
                scope=common.InstrumentationScope(name="io.opentelemetry.jdbc", version="1.0"),
                spans=spans,
            )],
        )
    ])
    return req.SerializeToString()


def main():
    data = build()
    path = os.path.join(HERE, "mixed.pb")
    with open(path, "wb") as fh:
        fh.write(data)
    print("mixed.pb  %d bytes  (1 trace: http root + 6 pg + 6 redis + 1 es)" % len(data))


if __name__ == "__main__":
    main()
