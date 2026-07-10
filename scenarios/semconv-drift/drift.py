#!/usr/bin/env python3
"""Rewrite an Astronomy Shop slice into a single-semconv-generation corpus.

OTel renamed the attribute keys perf-sentinel's detectors depend on
(db.statement -> db.query.text, db.system -> db.system.name,
http.method -> http.request.method, http.url -> url.full), and real fleets
emit any mix of the two generations during the migration
(OTEL_SEMCONV_STABILITY_OPT_IN). The product ingest is dual-keyed with a
documented preference per pair; this script rewrites the corpus into the
three pure shapes so verify.sh can assert the findings are identical:

  old-only  every pair resolved onto the legacy key (stable key removed
            or renamed down)
  new-only  every pair resolved onto the stable key - the corpus shape the
            lab otherwise never feeds (db.query.text without db.statement)
  dup       both keys present with the same value (the opt-in "dup" mode)

The resolved value is always the PREFERRED key's - the one ingest reads
first - so the rewrite is finding-preserving by construction even if a span
ever carries both keys with different values. Span-level attributes only;
resource/scope attributes are untouched (ingest does not read these keys
there). Streams line by line; document structure, span ids and timings are
never altered, so every output line stays a valid ExportTraceServiceRequest
with the exact same trace population.

usage: drift.py {old-only,new-only,dup} IN OUT
"""

import argparse
import json
import sys

# (old_key, new_key, preferred) - preferred = the key ingest resolves first.
# Mixed on purpose: db.system.name is NEW-preferred (otlp/mod.rs:225-230)
# while the other three pairs are OLD-preferred (otlp/mod.rs:567-586); a
# hardcoded "old wins" would be subtly wrong on a dual-keyed span.
PAIRS = [
    ("db.statement", "db.query.text", "old"),
    ("db.system", "db.system.name", "new"),
    ("http.method", "http.request.method", "old"),
    ("http.url", "url.full", "old"),
]


def parsed_lines(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                # Same stance as curate.py / `analyze --input` on a rotated dump.
                print(f"warn: skipping unparseable line {lineno}", file=sys.stderr)


def apply_pair(attrs, old, new, pref, mode, stats):
    o = next((a for a in attrs if a.get("key") == old), None)
    n = next((a for a in attrs if a.get("key") == new), None)
    if o is None and n is None:
        return
    preferred, other = (n, o) if pref == "new" else (o, n)
    value = (preferred if preferred is not None else other)["value"]
    if mode == "dup":
        if o is None:
            attrs.insert(attrs.index(n) + 1, {"key": old, "value": value})
            stats["copied"] += 1
        elif n is None:
            attrs.insert(attrs.index(o) + 1, {"key": new, "value": value})
            stats["copied"] += 1
        else:
            o["value"] = value
            n["value"] = value
        return
    keep_key, keep, drop = (old, o, n) if mode == "old-only" else (new, n, o)
    if keep is None:
        drop["key"] = keep_key  # rename in place, attribute order preserved
        drop["value"] = value
        stats["renamed"] += 1
    else:
        keep["value"] = value
        if drop is not None:
            attrs.remove(drop)
            stats["dropped"] += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["old-only", "new-only", "dup"])
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    per_pair = {old: {"renamed": 0, "dropped": 0, "copied": 0} for old, _, _ in PAIRS}
    lines_out = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for doc in parsed_lines(args.input):
            for rs in doc.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    for span in ss.get("spans", []):
                        attrs = span.get("attributes")
                        if not attrs:
                            continue
                        for old, new, pref in PAIRS:
                            apply_pair(attrs, old, new, pref, args.mode, per_pair[old])
            out.write(json.dumps(doc, separators=(",", ":")) + "\n")
            lines_out += 1

    for old, new, _ in PAIRS:
        s = per_pair[old]
        print(f"pair={old}->{new} renamed={s['renamed']} "
              f"dropped={s['dropped']} copied={s['copied']}")
    print(f"lines_out={lines_out}")


if __name__ == "__main__":
    main()
