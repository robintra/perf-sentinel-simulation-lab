#!/usr/bin/env python3
# Generate the two OTLP/protobuf payloads for ruby-activerecord-suggestion.
#
#   ruby-ar.pb       service.name = rails-shop. A Rack HTTP root plus six SQL
#                    children under the InstrumentationScope
#                    `OpenTelemetry::Instrumentation::ActiveRecord`. The
#                    statement is the SANITIZED Active Record form
#                    `SELECT * FROM orders WHERE id = $1` (params already
#                    collapsed to a placeholder by the OTel Ruby sanitizer),
#                    repeated 6x with VARIED durations (CV > 0.5). Under the
#                    lab's strict sanitizer-aware mode this needs BOTH the ORM
#                    scope marker AND timing variance to reclassify the
#                    sanitized group as n_plus_one_sql -> the finding is then
#                    enriched with suggested_fix.framework = ruby_active_record.
#
#   ruby-generic.pb  service.name = rails-generic. No ORM scope. Six SQL
#                    children with DISTINCT id literals (a standard N+1, mode
#                    independent) each carrying code.filepath =
#                    "app/models/order.rb" -> suggested_fix.framework =
#                    ruby_generic (the .rb filepath signal).
#
# Instrumentation scopes are captured ONLY at OTLP ingestion, so this MUST be
# OTLP/protobuf (the daemon's /v1/traces accepts only application/x-protobuf).
# `pip install opentelemetry-proto`. verify.sh replays the committed .pb.
import os

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NS = 1_749_297_600_000_000_000
AR_SCOPE = "OpenTelemetry::Instrumentation::ActiveRecord"
RACK_SCOPE = "OpenTelemetry::Instrumentation::Rack"
# Varied child durations (ms) -> coefficient of variation well above 0.5, the
# timing signal strict mode requires alongside the ORM scope.
VARIED_MS = [1, 3, 8, 20, 45, 2]


def kv(key, val):
    return common.KeyValue(key=key, value=common.AnyValue(string_value=val))


def root_span(trace_id):
    return trace.Span(
        trace_id=trace_id, span_id=(1).to_bytes(8, "big"),
        name="GET /api/orders", kind=trace.Span.SPAN_KIND_SERVER,
        start_time_unix_nano=BASE_NS, end_time_unix_nano=BASE_NS + 200_000_000,
        attributes=[kv("http.route", "/api/orders"), kv("url.full", "http://gw/api/orders")],
    )


def sql_child(trace_id, sid, statement, dur_ms, extra=None):
    start = BASE_NS + sid * 1_000_000
    attrs = [kv("db.system", "postgresql"), kv("db.statement", statement)]
    if extra:
        attrs.extend(extra)
    return trace.Span(
        trace_id=trace_id, span_id=sid.to_bytes(8, "big"), parent_span_id=(1).to_bytes(8, "big"),
        name="ActiveRecord", kind=trace.Span.SPAN_KIND_CLIENT,
        start_time_unix_nano=start, end_time_unix_nano=start + dur_ms * 1_000_000,
        attributes=attrs,
    )


def build_active_record():
    trace_id = (0xA1).to_bytes(16, "big")
    children = [sql_child(trace_id, i + 2, "SELECT * FROM orders WHERE id = $1", VARIED_MS[i])
                for i in range(6)]
    req = svc.ExportTraceServiceRequest(resource_spans=[
        trace.ResourceSpans(
            resource=resource.Resource(attributes=[kv("service.name", "rails-shop")]),
            scope_spans=[
                trace.ScopeSpans(scope=common.InstrumentationScope(name=RACK_SCOPE, version="0.25"),
                                 spans=[root_span(trace_id)]),
                trace.ScopeSpans(scope=common.InstrumentationScope(name=AR_SCOPE, version="0.7"),
                                 spans=children),
            ],
        )
    ])
    return req.SerializeToString()


def build_generic():
    trace_id = (0xA2).to_bytes(16, "big")
    rb = [kv("code.filepath", "app/models/order.rb"), kv("code.namespace", "Order")]
    children = [sql_child(trace_id, i + 2, "SELECT * FROM orders WHERE id = %d" % (i + 1),
                          VARIED_MS[i], extra=rb) for i in range(6)]
    req = svc.ExportTraceServiceRequest(resource_spans=[
        trace.ResourceSpans(
            resource=resource.Resource(attributes=[kv("service.name", "rails-generic")]),
            # No ORM scope: detection must fall back to the .rb code.filepath.
            scope_spans=[trace.ScopeSpans(spans=[root_span(trace_id), *children])],
        )
    ])
    return req.SerializeToString()


def main():
    for fname, data in (("ruby-ar.pb", build_active_record()),
                        ("ruby-generic.pb", build_generic())):
        with open(os.path.join(HERE, fname), "wb") as fh:
            fh.write(data)
        print("%s  %d bytes" % (fname, len(data)))


if __name__ == "__main__":
    main()
