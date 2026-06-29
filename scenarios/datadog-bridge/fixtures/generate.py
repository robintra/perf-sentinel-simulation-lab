#!/usr/bin/env python3
# Fixtures for the datadog-bridge scenario (0.9.3 Datadog/dd-trace ingestion
# bridge + the db-system classification hardening that shipped with it).
#
# Two encodings, mirroring the sibling 0.9.x self-contained scenarios:
#   OTLP/protobuf (*.pb)  -> daemon /v1/traces leg (scopes + dd.span.Resource +
#                            db.system.name are captured ONLY at OTLP ingestion).
#   Jaeger / Zipkin JSON  -> batch `analyze` / `explain` leg (cross-format
#                            canonicalization; these formats carry db.system in
#                            their tags, OTLP does not round-trip through analyze).
#
# Every dd-trace-bridged fixture mimics the REAL OTel Collector datadogreceiver
# output (captured from contrib v0.155.0): instrumentation scope "Datadog",
# SQL already obfuscated (`?`) in dd.span.Resource, the engine under the stable
# OTel 1.27+ key db.system.name (NOT db.system / db.type), unless a fixture
# deliberately exercises the dd-trace db.type meta key.
#
# OTLP needs `pip install opentelemetry-proto`; the JSON paths are stdlib only.
# verify.sh replays the committed fixtures and never runs this generator.
import json
import os

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
from opentelemetry.proto.common.v1 import common_pb2 as common
from opentelemetry.proto.resource.v1 import resource_pb2 as resource
from opentelemetry.proto.trace.v1 import trace_pb2 as trace

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NS = 1_749_297_600_000_000_000
BASE_US = BASE_NS // 1000          # same fixed epoch, microseconds (Jaeger/Zipkin)

DD_SCOPE = "Datadog"                 # verbatim scope the datadogreceiver attaches
DD_SCOPE_VER = "Datadog 2.9.0"
OBF = "SELECT * FROM order_item WHERE order_id = ?"        # dd-trace pre-obfuscated
OBF_SNOW = "SELECT * FROM warehouse.orders WHERE id = ?"   # cloud SQL engine
UNIFORM = [5, 6, 4, 5, 6, 4]         # warm cache, CV < 0.5, fits the 500ms window

# ── OTLP/protobuf (daemon leg) ──────────────────────────────────────────────


def kv(key, val):
    return common.KeyValue(key=key, value=common.AnyValue(string_value=val))


def _root(trace_id):
    return trace.Span(
        trace_id=trace_id, span_id=(1).to_bytes(8, "big"),
        name="GET /api/orders", kind=trace.Span.SPAN_KIND_SERVER,
        # 120ms: a normal web root. NOT seconds — a slow root would raise an
        # orthogonal slow_http finding and muddy the per-service type asserts.
        start_time_unix_nano=BASE_NS, end_time_unix_nano=BASE_NS + 120_000_000,
        attributes=[kv("http.route", "/api/orders"), kv("url.full", "http://gw/api/orders")],
    )


def _seq_children(trace_id, specs):
    """specs: list of (attrs, dur_ms). Sequential (non-overlapping) siblings."""
    out, cur = [], BASE_NS + 1_000_000
    for i, (attrs, dur_ms) in enumerate(specs):
        out.append(trace.Span(
            trace_id=trace_id, span_id=(i + 2).to_bytes(8, "big"),
            parent_span_id=(1).to_bytes(8, "big"),
            name="postgres.query", kind=trace.Span.SPAN_KIND_CLIENT,
            start_time_unix_nano=cur, end_time_unix_nano=cur + dur_ms * 1_000_000,
            attributes=attrs))
        cur += (dur_ms + 1) * 1_000_000
    return out


def otlp_payload(trace_id_byte, service, specs):
    trace_id = bytes([trace_id_byte]) + b"\x00" * 15
    req = svc.ExportTraceServiceRequest(resource_spans=[trace.ResourceSpans(
        resource=resource.Resource(attributes=[
            kv("service.name", service), kv("telemetry.sdk.name", "Datadog")]),
        scope_spans=[trace.ScopeSpans(
            scope=common.InstrumentationScope(name=DD_SCOPE, version=DD_SCOPE_VER),
            spans=[_root(trace_id)] + _seq_children(trace_id, specs))])])
    return req.SerializeToString()


def dd_sql_specs(resource_sql, db_attr_key, db_attr_val, n, durations):
    a = [[kv("dd.span.Resource", resource_sql), kv(db_attr_key, db_attr_val)]
         for _ in range(n)]
    return list(zip(a, [durations[i % len(durations)] for i in range(n)]))


def build_otlp_fixtures():
    out = {}
    # A + F(auto): real receiver shape (db.system.name), obfuscated, uniform x6.
    out["dd-bridge-nplusone.pb"] = otlp_payload(
        0xD1, "dd-bridge-shop",
        dd_sql_specs(OBF, "db.system.name", "postgres", 6, UNIFORM))
    # F(strict): same, x16 -> high_occurrence (>=3x threshold) recovers n+1.
    out["dd-bridge-16.pb"] = otlp_payload(
        0xD2, "dd-bridge-shop16",
        dd_sql_specs(OBF, "db.system.name", "postgres", 16, UNIFORM))
    # E: cloud SQL engine via the dd-trace db.type meta key.
    out["dd-snowflake.pb"] = otlp_payload(
        0xD3, "dd-snowflake-shop",
        dd_sql_specs(OBF_SNOW, "db.type", "snowflake", 6, UNIFORM))
    # B + G: non-SQL stores (must drop, never tokenize, no key leak) + one
    # statement-less SQL span (instrumentation gap -> missing_db_statement).
    specs = []
    for i in range(6):  # redis via dd-trace db.type
        specs.append(([kv("db.type", "redis"),
                       kv("dd.span.Resource", "GET user:SECRET-REDIS-%d" % i)], 2))
    for i in range(6):  # dynamodb via stable namespaced db.system.name
        specs.append(([kv("db.system.name", "aws.dynamodb"),
                       kv("db.statement", "GetItem pk=SECRET-DDB-%d" % i)], 2))
    specs.append(([kv("db.system.name", "postgres")], 2))  # SQL gap, no statement
    out["nonsql-and-gap.pb"] = otlp_payload(0xD4, "dd-nonsql-shop", specs)
    return out


# ── Jaeger / Zipkin (batch leg, cross-format canonicalization) ──────────────

XF_TRACE = "t0000000000000000000000000000a0e0"
XF_SVC = "dd-xfmt-shop"


def _span_id(sid):
    return "s%016x" % ((0xA0E0 << 16) | sid)


def xf_spans():
    """One trace exercising canonical_db_system + db.system.name across formats."""
    out = [(1, None, "GET /api/orders", 120_000,
            {"http.route": "/api/orders", "url.full": "http://gw/api/orders"})]
    sid = 2
    # group P: legacy db.system="postgres" -> canonical operation "postgresql"
    for i in range(1, 7):
        out.append((sid, 1, "db-query", 800,
                    {"db.system": "postgres",
                     "db.statement": "SELECT * FROM orders WHERE id = %d" % i})); sid += 1
    # group S: stable db.system.name="postgres" (no legacy key) -> SQL finding
    for i in range(1, 7):
        out.append((sid, 1, "db-query", 800,
                    {"db.system.name": "postgres",
                     "db.statement": "SELECT * FROM line_items WHERE order_id = %d" % i})); sid += 1
    # group X: NO db system at all -> operation label falls back to "sql"
    for i in range(1, 7):
        out.append((sid, 1, "db-query", 800,
                    {"db.statement": "SELECT * FROM users WHERE uid = %d" % i})); sid += 1
    # drop: stable namespaced non-SQL store -> dropped, key must not leak
    out.append((sid, 1, "ddb-get", 1_500,
                {"db.system.name": "aws.dynamodb",
                 "db.statement": "GetItem pk=SECRET-DDB-XF"}))
    return out


def to_jaeger(spans):
    jspans = [{
        "spanID": _span_id(sid),
        "operationName": name,
        "references": ([{"refType": "CHILD_OF", "spanID": _span_id(parent)}] if parent else []),
        "startTime": BASE_US + sid * 1000, "duration": dur, "processID": "p1",
        "tags": [{"key": k, "value": v} for k, v in attrs.items()],
    } for sid, parent, name, dur, attrs in spans]
    return {"data": [{"traceID": XF_TRACE, "spans": jspans,
                      "processes": {"p1": {"serviceName": XF_SVC}}}]}


def to_zipkin(spans):
    out = []
    for sid, parent, name, dur, attrs in spans:
        z = {"traceId": XF_TRACE, "id": _span_id(sid), "name": name,
             "timestamp": BASE_US + sid * 1000, "duration": dur,
             "localEndpoint": {"serviceName": XF_SVC}, "tags": dict(attrs)}
        if parent:
            z["parentId"] = _span_id(parent)
        out.append(z)
    return out


def main():
    written = []
    for name, data in build_otlp_fixtures().items():
        with open(os.path.join(HERE, name), "wb") as fh:
            fh.write(data)
        written.append("%s (%d bytes)" % (name, len(data)))
    spans = xf_spans()
    for name, payload in (("crossfmt-jaeger.json", to_jaeger(spans)),
                          ("crossfmt-zipkin.json", to_zipkin(spans))):
        with open(os.path.join(HERE, name), "w") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
        written.append(name)
    for w in written:
        print(w)


if __name__ == "__main__":
    main()
