#!/usr/bin/env python3
"""Curate a committed replay slice from a full Astronomy Shop capture.

Input is an OTel Collector file-exporter NDJSON dump: one
ExportTraceServiceRequest JSON document per line. A trace's spans arrive
spread across many lines (every service exports on its own schedule), and
traces touching the edges of the capture window may be missing spans that
were emitted while the collector was down. So:

  pass 1  index traceId -> [min start, max end] across ALL lines,
  select  traces fully inside [window start + guard, window end - guard],
          deterministic order (min start, traceId), first N,
  pass 2  re-emit each line filtered to the selected traces' spans only,
          preserving resource/scope grouping and arrival order, so every
          output line stays a valid ExportTraceServiceRequest.

Both passes stream line by line - full dumps run to hundreds of MB and are
never loaded whole.
# ponytail: whole-trace index in RAM, switch to sqlite if captures outgrow it

usage: curate.py IN.ndjson OUT.ndjson [--traces N] [--edge-guard SECONDS]
"""

import argparse
import collections
import json
import sys


def parsed_lines(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                # Tolerate an in-flight truncated final write, same stance
                # as `analyze --input` on a rotated dump.
                print(f"warn: skipping unparseable line {lineno}", file=sys.stderr)


def each_span(doc):
    for rs in doc.get("resourceSpans", []):
        for ss in rs.get("scopeSpans", []):
            for span in ss.get("spans", []):
                yield rs, span


def service_name(rs):
    for attr in rs.get("resource", {}).get("attributes", []):
        if attr.get("key") == "service.name":
            return attr.get("value", {}).get("stringValue", "?")
    return "?"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--traces", type=int, default=300)
    ap.add_argument("--edge-guard", type=int, default=30, metavar="SECONDS")
    args = ap.parse_args()

    # Pass 1: trace extents + capture window.
    extents = {}          # traceId -> [min start, max end], ns
    incomplete = set()    # traces with a missing/zero timestamp
    win_min, win_max = None, None
    for doc in parsed_lines(args.input):
        for _, span in each_span(doc):
            tid = span.get("traceId", "")
            start = int(span.get("startTimeUnixNano", 0))
            end = int(span.get("endTimeUnixNano", 0))
            if not tid or start == 0 or end == 0:
                incomplete.add(tid)
                continue
            win_min = start if win_min is None else min(win_min, start)
            win_max = end if win_max is None else max(win_max, end)
            ext = extents.setdefault(tid, [start, end])
            ext[0] = min(ext[0], start)
            ext[1] = max(ext[1], end)
    if win_min is None:
        sys.exit("error: no spans found in the dump")

    guard_ns = args.edge_guard * 1_000_000_000
    lo, hi = win_min + guard_ns, win_max - guard_ns
    eligible = [
        (ext[0], tid)
        for tid, ext in extents.items()
        if tid not in incomplete and ext[0] >= lo and ext[1] <= hi
    ]
    eligible.sort()
    if len(eligible) < max(1, args.traces // 3):
        sys.exit(
            f"error: only {len(eligible)} eligible traces for a {args.traces}-trace "
            f"slice - capture window too short, raise CLEAN_MINUTES/DEGRADED_MINUTES"
        )
    selected = {tid for _, tid in eligible[: args.traces]}

    # Pass 2: re-emit only the selected traces' spans.
    lines_out = 0
    census = collections.Counter()
    with open(args.output, "w", encoding="utf-8") as out:
        for doc in parsed_lines(args.input):
            kept_rs = []
            for rs in doc.get("resourceSpans", []):
                kept_ss = []
                for ss in rs.get("scopeSpans", []):
                    spans = [s for s in ss.get("spans", []) if s.get("traceId") in selected]
                    if spans:
                        kept_ss.append({**ss, "spans": spans})
                        census[service_name(rs)] += len(spans)
                if kept_ss:
                    kept_rs.append({**rs, "scopeSpans": kept_ss})
            if kept_rs:
                out.write(json.dumps({**doc, "resourceSpans": kept_rs},
                                     separators=(",", ":")) + "\n")
                lines_out += 1

    window_s = (win_max - win_min) / 1e9
    print(f"window: {window_s:.0f}s, traces total={len(extents)} "
          f"eligible={len(eligible)} selected={len(selected)}, lines out={lines_out}")
    print("spans per service:")
    for svc, count in census.most_common():
        print(f"  {count:6d}  {svc}")


if __name__ == "__main__":
    main()
