#!/usr/bin/env python3
# Generate the two OTLP/protobuf trace fixtures replayed by verify.sh.
#
# perf-sentinel's OTLP HTTP receiver accepts ONLY application/x-protobuf
# (the JSON-encoded OTLP variant is not implemented), so the scenario
# cannot hand-write a JSON payload. telemetrygen emits generic spans with
# no SQL semantics, so it cannot form an N+1 either. We therefore ship two
# static, pre-encoded ExportTraceServiceRequest payloads, each a single
# trace carrying six SQL child spans that share one normalized template
# but differ in their bound id literal:
#
#     SELECT * FROM <table> WHERE id = 1 .. 6
#
# Six distinct param sets over one template clears the lab's
# n_plus_one_min_occurrences = 5 via the detector's DIRECT rule
# (distinct_params >= threshold), so it does not depend on the
# sanitizer-aware "strict" heuristic. Each fixture uses a distinct
# service.name and table so the positive and negative controls never
# alias in the shared NDJSON archive.
#
# This script is provenance/documentation only. verify.sh never runs it.
# It replays the committed .pb files with curl. Regenerating needs the
# `opentelemetry-proto` package (pip install opentelemetry-proto); the
# span timestamps are irrelevant to detection because the daemon keys its
# streaming-window TTL on span ARRIVAL time, not on the span clock.
import os

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

HERE = os.path.dirname(os.path.abspath(__file__))
# Fixed base timestamp (2026-06-07T12:00:00Z in unix nanos). Detection is
# clock-independent. A constant keeps the .pb bytes reproducible.
BASE_NS = 1_749_297_600_000_000_000


def sval(s):
    return common.AnyValue(string_value=s)


def kv(key, s):
    return common.KeyValue(key=key, value=sval(s))


def build(service_name, table, trace_id, root_id, child_seed):
    spans = [
        trace.Span(
            trace_id=trace_id,
            span_id=root_id,
            name="GET /probe",
            kind=trace.Span.SPAN_KIND_SERVER,
            start_time_unix_nano=BASE_NS,
            end_time_unix_nano=BASE_NS + 200_000_000,
            attributes=[kv("http.route", "/probe")],
        )
    ]
    for n in range(1, 7):  # six distinct id literals -> distinct_params = 6
        start = BASE_NS + n * 10_000_000
        spans.append(
            trace.Span(
                trace_id=trace_id,
                span_id=bytes([child_seed, 0, 0, 0, 0, 0, 0, n]),
                parent_span_id=root_id,
                name="SELECT " + table,
                kind=trace.Span.SPAN_KIND_CLIENT,
                start_time_unix_nano=start,
                end_time_unix_nano=start + 5_000_000,
                attributes=[
                    kv("db.system", "postgresql"),
                    kv("db.statement", "SELECT * FROM %s WHERE id = %d" % (table, n)),
                ],
            )
        )
    req = svc.ExportTraceServiceRequest(
        resource_spans=[
            trace.ResourceSpans(
                resource=resource.Resource(attributes=[kv("service.name", service_name)]),
                scope_spans=[
                    trace.ScopeSpans(
                        scope=common.InstrumentationScope(name="sigterm-drain-probe", version="1.0"),
                        spans=spans,
                    )
                ],
            )
        ]
    )
    return req.SerializeToString()


def main():
    cases = [
        ("sigterm-drain-positive", "probe_positive", b"\xa0" * 16, b"\xa1" * 8, 0x10, "n-plus-one-positive.pb"),
        ("sigterm-drain-negative", "probe_negative", b"\xb0" * 16, b"\xb1" * 8, 0x20, "n-plus-one-negative.pb"),
    ]
    for service_name, table, trace_id, root_id, child_seed, fname in cases:
        data = build(service_name, table, trace_id, root_id, child_seed)
        path = os.path.join(HERE, fname)
        with open(path, "wb") as fh:
            fh.write(data)
        print("%s  %d bytes  service=%s" % (fname, len(data), service_name))


if __name__ == "__main__":
    main()
