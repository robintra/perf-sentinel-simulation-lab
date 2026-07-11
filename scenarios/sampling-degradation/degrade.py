#!/usr/bin/env python3
"""Degrade an Astronomy Shop replay slice the way production telemetry would.

Input is curate.py output: OTLP/JSON NDJSON, one ExportTraceServiceRequest
per line, whole traces. Production never delivers that ideal corpus - almost
every deployment samples, and collectors drop spans under pressure - so this
script produces the two degraded shapes deterministically:

  trace-sample  keep a span iff fnv1a64(traceId)/2^64 < keep-rate. Whole-trace
                consistency is automatic (the decision is a pure function of
                traceId) and keep-sets are NESTED across rates (same hash,
                threshold compare), which is what makes verify.sh's monotone
                assertion sound. The hash is a byte-for-byte port of the
                product's own ingest down-sampler (daemon/sampling.rs), so the
                lab's "external sampler" and the product agree on keep-sets.
  span-loss     keep every root span; drop a non-root span iff
                fnv1a64(traceId + spanId)/2^64 < drop-rate. Simulates
                collector loss: partial call graphs with broken parentage.

Streams line by line and re-emits only non-empty documents, so every output
line stays a valid ExportTraceServiceRequest. The stats line on stdout is
machine-read by verify.sh as its anti-vacuity guard.

usage: degrade.py trace-sample IN OUT --keep-rate R
       degrade.py span-loss    IN OUT --drop-rate R
"""

import argparse
import json
import sys

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
U64 = 1 << 64


def fnv1a64(s):
    h = FNV_OFFSET
    for b in s.encode():
        h = ((h ^ b) * FNV_PRIME) % U64
    return h


# Port check against daemon/sampling.rs (standard FNV-1a 64 test vector) -
# a botched port would silently reshuffle every keep-set.
assert fnv1a64("a") == 0xAF63DC4C8601EC8C


def parsed_lines(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                doc = json.loads(line)
            except json.JSONDecodeError:
                # Same stance as curate.py / `analyze --input` on a rotated dump.
                print(f"warn: skipping unparseable line {lineno}", file=sys.stderr)
                continue
            if not isinstance(doc, dict):
                # A bare scalar (null/number) from a rotated dump is valid JSON
                # but not an ExportTraceServiceRequest; skip rather than crash.
                print(f"warn: skipping non-object line {lineno}", file=sys.stderr)
                continue
            yield doc


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["trace-sample", "span-loss"])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--keep-rate", type=float)
    ap.add_argument("--drop-rate", type=float)
    args = ap.parse_args()

    if args.mode == "trace-sample":
        if args.keep_rate is None:
            ap.error("trace-sample requires --keep-rate")
        rate = args.keep_rate

        def keep(span):
            tid = span.get("traceId", "")
            return bool(tid) and fnv1a64(tid) / U64 < rate
    else:
        if args.drop_rate is None:
            ap.error("span-loss requires --drop-rate")
        rate = args.drop_rate

        def keep(span):
            if not span.get("parentSpanId"):
                return True  # roots always survive: the loss is downstream
            return fnv1a64(span.get("traceId", "") + span.get("spanId", "")) / U64 >= rate

    kept_tids = set()
    kept_spans = dropped_spans = lines_out = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for doc in parsed_lines(args.input):
            kept_rs = []
            for rs in doc.get("resourceSpans", []):
                kept_ss = []
                for ss in rs.get("scopeSpans", []):
                    spans = []
                    for span in ss.get("spans", []):
                        if keep(span):
                            spans.append(span)
                            kept_spans += 1
                            kept_tids.add(span.get("traceId", ""))
                        else:
                            dropped_spans += 1
                    if spans:
                        kept_ss.append({**ss, "spans": spans})
                if kept_ss:
                    kept_rs.append({**rs, "scopeSpans": kept_ss})
            if kept_rs:
                out.write(json.dumps({**doc, "resourceSpans": kept_rs},
                                     separators=(",", ":")) + "\n")
                lines_out += 1

    print(f"kept_traces={len(kept_tids)} kept_spans={kept_spans} "
          f"dropped_spans={dropped_spans} lines_out={lines_out}")


if __name__ == "__main__":
    main()
