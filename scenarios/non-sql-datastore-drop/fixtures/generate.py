#!/usr/bin/env python3
# Generate the mixed redis + postgres + elasticsearch fixtures for the
# non-sql-datastore-drop scenario (0.9.2 ingest/ changes).
#
# Each fixture is ONE trace mixing:
#   - 1 HTTP SERVER root.
#   - 6 PostgreSQL SQL children: SELECT * FROM orders WHERE id = 1..6 -> a
#     real N+1 (the ONLY thing that must survive and produce a finding).
#   - 6 Redis children: db.system=redis, db.statement="GET user:1..6". With
#     distinct keys these would otherwise group into a finding. The 0.9.2
#     drop on db.system must remove them at ingestion, before any tokenizer.
#   - 1 Elasticsearch child carrying BOTH db.statement AND url.full: must be
#     dropped on db.system (not reclassified as an HTTP finding).
#
# Three on-disk encodings mirror tools/tracegen/tracegen.py exactly:
#   mixed-jaeger.json  (Jaeger v1: tags = [{key,value}], processes{})
#   mixed-zipkin.json  (Zipkin v2: flat span array, tags = {k:v} map)
# The OTLP/protobuf encoding for the daemon leg lives in generate-otlp.py.
#
# stdlib-only. verify.sh consumes the committed JSON. It never runs this.
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_US = 1_749_297_600_000_000  # microseconds (Jaeger/Zipkin use micros)
TRACE = "t000000000000000000000000000000c0"
SVC = "shop-mixed"


def spans_abstract():
    """One trace as a list of abstract spans: (sid, parent, name, kind, dur_us, attrs)."""
    out = [(1, None, "GET /api/orders", "server", 120_000,
            {"http.route": "/api/orders", "url.full": "http://gw/api/orders"})]
    sid = 2
    # 6 postgres N+1 (the survivor)
    for i in range(1, 7):
        out.append((sid, 1, "db-query", "client", 2_000,
                    {"db.system": "postgresql",
                     "db.statement": "SELECT * FROM orders WHERE id = %d" % i}))
        sid += 1
    # 6 redis (must be dropped on db.system)
    for i in range(1, 7):
        out.append((sid, 1, "redis-GET", "client", 800,
                    {"db.system": "redis", "db.statement": "GET user:%d" % i}))
        sid += 1
    # 1 elasticsearch carrying db.statement AND url.full (edge: dropped, not HTTP)
    out.append((sid, 1, "es-search", "client", 5_000,
                {"db.system": "elasticsearch",
                 "db.statement": "GET /orders/_search",
                 "url.full": "http://es:9200/orders/_search"}))
    return out


def span_id(sid):
    return "s%016x" % ((0xC0 << 20) | sid)


def to_jaeger(spans):
    jspans = []
    for sid, parent, name, _kind, dur, attrs in spans:
        js = {
            "spanID": span_id(sid),
            "operationName": name,
            "references": ([{"refType": "CHILD_OF", "spanID": span_id(parent)}] if parent else []),
            "startTime": BASE_US + sid * 1000,
            "duration": dur,
            "processID": "p1",
            "tags": [{"key": k, "value": v} for k, v in attrs.items()],
        }
        jspans.append(js)
    return {"data": [{"traceID": TRACE, "spans": jspans,
                      "processes": {"p1": {"serviceName": SVC}}}]}


def to_zipkin(spans):
    out = []
    for sid, parent, name, _kind, dur, attrs in spans:
        z = {
            "traceId": TRACE,
            "id": span_id(sid),
            "name": name,
            "timestamp": BASE_US + sid * 1000,
            "duration": dur,
            "localEndpoint": {"serviceName": SVC},
            "tags": dict(attrs),
        }
        if parent:
            z["parentId"] = span_id(parent)
        out.append(z)
    return out


def main():
    spans = spans_abstract()
    for name, payload in (
        ("mixed-jaeger.json", to_jaeger(spans)),
        ("mixed-zipkin.json", to_zipkin(spans)),
    ):
        with open(os.path.join(HERE, name), "w") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
        print("%s written" % name)


if __name__ == "__main__":
    main()
