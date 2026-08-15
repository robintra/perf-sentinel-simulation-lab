#!/usr/bin/env python3
"""Convert an Alibaba v2022 CallGraph CSV into an OTLP/JSON NDJSON slice.

Input is one extracted CallGraph_<n>.csv from the Alibaba
cluster-trace-microservices-v2022 dataset (3 minutes of production
traffic, ~17k microservices): one row per call edge
(um --rpctype/interface--> dm) with a hierarchical rpc_id encoding
parentage (0.1 is the parent of 0.1.1) and a per-trace traceid.

The dataset carries REAL production topology, timing, and service
cardinality but no rich attributes (no SQL text, no URLs), and it has
known topological inconsistencies (missing parents; RPC calls recorded
twice, once by each side). So:

  pass 1  stream the CSV, dedup (traceid, rpc_id) first-wins, index each
          trace's rpc_id set + earliest timestamp + row count,
  select  traces whose call tree is CONSISTENT (exactly one root: every
          other rpc_id's parent is present - the cheap version of the
          CASPER reconstruction filter) and inside [--min-spans,
          --max-spans], deterministic order (earliest timestamp,
          traceid), first --traces,
  pass 2  re-stream and emit one ExportTraceServiceRequest per selected
          trace, spans grouped per um service.

Attribute mapping is a documented compromise: perf-sentinel's ingest
keeps only I/O-shaped spans, so every call is emitted as an HTTP client
span with a SYNTHETIC carrier url `http://<dm>/<interface>`; topology
(parentage, fanout, chains), timing (timestamp + rt), and service names
are the real production data, the url is just the vehicle. rpctype and
the Alibaba service id ride along as extra attributes.

Ids are md5-derived from (traceid, rpc_id): deterministic, valid OTLP
hex. Timestamps are the dataset's relative ms offsets anchored on a
fixed epoch so replay is byte-stable.
# ponytail: per-trace rpc_id index in RAM (~100 MB for a 3-min file),
# switch to sqlite if a multi-file corpus outgrows it

usage: convert.py IN.csv OUT.ndjson [--traces N] [--min-spans N] [--max-spans N]
"""

import argparse
import csv
import hashlib
import json
import sys

# 2022-01-01T00:00:00Z in ms - fixed anchor for the dataset's relative
# timestamps, so the emitted slice is deterministic.
BASE_EPOCH_MS = 1_640_995_200_000


# Columns read in pass 2. Validated once so a schema variant fails with an
# actionable message instead of a KeyError traceback mid-conversion.
REQUIRED_COLUMNS = (
    "timestamp", "traceid", "service", "rpc_id", "rpctype", "um", "interface", "dm", "rt",
)


def num(s):
    """Best-effort float. The dataset carries rt="None" (~0.7% of rows,
    UNAVAILABLE edges) and field-shifted rows with a service id in a numeric
    slot; coerce those to 0 rather than crash - this scenario validates
    topology, and a zeroed duration keeps the edge."""
    try:
        return float(s)
    except (TypeError, ValueError):
        return 0.0


def parent_of(rpc_id):
    return rpc_id.rsplit(".", 1)[0] if "." in rpc_id else None


def rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = [c for c in REQUIRED_COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            sys.exit(f"error: input CSV missing columns {missing} - not a v2022 CallGraph file?")
        for row in reader:
            tid, rpc = row.get("traceid", ""), row.get("rpc_id", "")
            if tid and rpc:
                yield tid, rpc, row


def span_id(trace_id, rpc_id):
    return hashlib.md5(f"{trace_id}|{rpc_id}".encode()).hexdigest()[:16]


def to_span(tid, rpc, row, rpc_ids):
    ts_ms = int(num(row["timestamp"]))
    rt_ms = max(num(row["rt"]), 0.0)
    start_ns = (BASE_EPOCH_MS + ts_ms) * 1_000_000
    parent = parent_of(rpc)
    interface = row["interface"] or row["dm"]
    return {
        "traceId": hashlib.md5(tid.encode()).hexdigest(),
        "spanId": span_id(tid, rpc),
        **({"parentSpanId": span_id(tid, parent)} if parent in rpc_ids else {}),
        "name": interface,
        "kind": 3,  # SPAN_KIND_CLIENT: each row is um calling dm
        "startTimeUnixNano": str(start_ns),
        "endTimeUnixNano": str(start_ns + int(rt_ms * 1_000_000)),
        "attributes": [
            # Synthetic carrier so ingest keeps the span. Dm+interface are real.
            {"key": "http.url",
             "value": {"stringValue": f"http://{row['dm']}/{interface}"}},
            {"key": "http.method", "value": {"stringValue": "POST"}},
            {"key": "rpc.system", "value": {"stringValue": row["rpctype"] or "rpc"}},
            {"key": "alibaba.service", "value": {"stringValue": row["service"]}},
        ],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--traces", type=int, default=300)
    ap.add_argument("--min-spans", type=int, default=5)
    ap.add_argument("--max-spans", type=int, default=300)
    args = ap.parse_args()

    # Pass 1: dedup + per-trace index.
    index = {}  # traceid -> {"ids": set(rpc_id), "first_ts": int}
    dup_rows = 0
    for tid, rpc, row in rows(args.input):
        entry = index.setdefault(tid, {"ids": set(), "first_ts": float("inf")})
        if rpc in entry["ids"]:
            dup_rows += 1  # RPC recorded by both sides - first wins
            continue
        entry["ids"].add(rpc)
        entry["first_ts"] = min(entry["first_ts"], int(num(row["timestamp"])))

    eligible = []
    inconsistent = 0
    for tid, entry in index.items():
        ids = entry["ids"]
        if not (args.min_spans <= len(ids) <= args.max_spans):
            continue
        roots = [r for r in ids if parent_of(r) not in ids]
        if len(roots) != 1:
            inconsistent += 1  # missing parents / forest: the known dataset quirk
            continue
        eligible.append((entry["first_ts"], tid))
    eligible.sort()
    if len(eligible) < args.traces:
        sys.exit(
            f"error: only {len(eligible)} consistent traces in "
            f"[{args.min_spans},{args.max_spans}] spans - need {args.traces}, "
            f"feed a bigger CSV or loosen the bounds"
        )
    selected = {tid for _, tid in eligible[: args.traces]}

    # Pass 2: emit one ExportTraceServiceRequest per trace, spans grouped
    # by um (the caller is the service emitting the client span).
    emitted = {tid: {} for tid in selected}  # tid -> {um: [span]}
    seen = {tid: set() for tid in selected}
    span_count = 0
    for tid, rpc, row in rows(args.input):
        if tid not in selected or rpc in seen[tid]:
            continue
        seen[tid].add(rpc)
        emitted[tid].setdefault(row["um"], []).append(
            to_span(tid, rpc, row, index[tid]["ids"])
        )
        span_count += 1

    with open(args.output, "w", encoding="utf-8") as out:
        for _, tid in eligible[: args.traces]:
            doc = {
                "resourceSpans": [
                    {
                        "resource": {"attributes": [
                            {"key": "service.name", "value": {"stringValue": um}},
                        ]},
                        "scopeSpans": [{
                            "scope": {"name": "alibaba-callgraph-v2022"},
                            "spans": spans,
                        }],
                    }
                    for um, spans in sorted(emitted[tid].items())
                ]
            }
            out.write(json.dumps(doc, separators=(",", ":")) + "\n")

    print(
        f"traces_total={len(index)} dup_rows={dup_rows} "
        f"inconsistent={inconsistent} eligible={len(eligible)} "
        f"selected={len(selected)} spans_out={span_count}"
    )


if __name__ == "__main__":
    main()
