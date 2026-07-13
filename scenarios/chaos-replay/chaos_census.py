#!/usr/bin/env python3
"""Census helpers shared by capture.sh (stamping) and verify.sh (recompute).

slice mode: stream a Collector file-exporter NDJSON slice and count the
chaos signal the choreography must have left behind:
  error_spans            spans with status.code == ERROR (2)
  broken_parent_traces   traces with >= 1 span whose parentSpanId never
                         appears among the trace's span ids - the killed
                         service's spans died in its exporter buffer while
                         its callees' SERVER spans still exported.

findings mode: reduce an `analyze --format json` output to the deterministic
replay contract: traces_analyzed and the per-class finding census.

usage: chaos_census.py slice CHAOS.ndjson
       chaos_census.py findings ANALYZE-OUT.json
Prints one compact sorted-key JSON object on stdout.
"""

import collections
import json
import sys


def slice_stats(path):
    error_spans = 0
    span_ids = collections.defaultdict(set)
    parent_ids = collections.defaultdict(set)
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            doc = json.loads(line)
            for rs in doc.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    for span in ss.get("spans", []):
                        tid = span.get("traceId", "")
                        span_ids[tid].add(span.get("spanId", ""))
                        parent = span.get("parentSpanId", "") or ""
                        if parent:
                            parent_ids[tid].add(parent)
                        code = span.get("status", {}).get("code")
                        if str(code) in ("2", "STATUS_CODE_ERROR"):
                            error_spans += 1
    broken = sum(1 for tid, parents in parent_ids.items()
                 if parents - span_ids[tid])
    return {"error_spans": error_spans, "broken_parent_traces": broken}


def findings_stats(path):
    doc = json.load(open(path, encoding="utf-8"))
    items = doc if isinstance(doc, list) else doc.get("findings", [])

    def unwrap(item):
        return item.get("finding", item) if isinstance(item, dict) else {}

    census = collections.Counter(unwrap(it).get("type", "?") for it in items)
    analyzed = (doc.get("analysis") or {}).get("traces_analyzed", 0) \
        if isinstance(doc, dict) else 0
    return {"traces_analyzed": analyzed, "finding_census": dict(census)}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("slice", "findings"):
        sys.exit(__doc__)
    stats = (slice_stats if sys.argv[1] == "slice" else findings_stats)(sys.argv[2])
    print(json.dumps(stats, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
