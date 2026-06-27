#!/usr/bin/env python3
# Generate the two OTLP/protobuf payloads for non-sql-datastore-metering.
#
#   redis-only.pb     1250 Redis spans (db.system=redis), nothing analyzable.
#                     Every span is dropped as non_sql_datastore. The 0.9.2
#                     /api/status zero-retention warning EXCLUDES
#                     non_sql_datastore from its gap sum, so a Redis-only fleet
#                     must NOT raise the "all received OTLP spans were filtered
#                     as non-analyzable" warning.
#
#   internal-only.pb  1250 internal spans (no db.*, no http.* attributes).
#                     Every span is dropped as not_io. not_io STILL counts
#                     toward the gap, so this fleet MUST raise the warning.
#                     This is the negative control proving the warning still
#                     fires for genuine zero-retention instrumentation gaps.
#
# Both exceed TUNING_ZERO_RETENTION_MIN_RECEIVED (1000), the warning's
# received-count floor. Replayed against a FRESH daemon (received/filtered are
# cumulative, so the warning is a whole-daemon condition).
#
# `pip install opentelemetry-proto`. verify.sh replays the committed .pb.
import os

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NS = 1_749_297_600_000_000_000
SPANS = 1250


def kv(key, val):
    return common.KeyValue(key=key, value=common.AnyValue(string_value=val))


def build(kind):
    spans = []
    for i in range(1, SPANS + 1):
        start = BASE_NS + i * 1_000_000
        if kind == "redis":
            attrs = [kv("db.system", "redis"), kv("db.statement", "GET key:%d" % i)]
            name = "redis-GET"
        else:  # internal: no db.*, no http.* -> not_io
            attrs = [kv("thread.name", "worker-%d" % (i % 8))]
            name = "compute"
        spans.append(trace.Span(
            trace_id=i.to_bytes(16, "big"),
            span_id=(i * 8 + 1).to_bytes(8, "big"),
            name=name,
            kind=trace.Span.SPAN_KIND_CLIENT if kind == "redis" else trace.Span.SPAN_KIND_INTERNAL,
            start_time_unix_nano=start,
            end_time_unix_nano=start + 500_000,
            attributes=attrs,
        ))
    svc_name = "redis-fleet" if kind == "redis" else "internal-fleet"
    req = svc.ExportTraceServiceRequest(resource_spans=[
        trace.ResourceSpans(
            resource=resource.Resource(attributes=[kv("service.name", svc_name)]),
            scope_spans=[trace.ScopeSpans(spans=spans)],
        )
    ])
    return req.SerializeToString()


def main():
    for kind, fname in (("redis", "redis-only.pb"), ("internal", "internal-only.pb")):
        data = build(kind)
        with open(os.path.join(HERE, fname), "wb") as fh:
            fh.write(data)
        print("%s  %d bytes  %d spans" % (fname, len(data), SPANS))


if __name__ == "__main__":
    main()
