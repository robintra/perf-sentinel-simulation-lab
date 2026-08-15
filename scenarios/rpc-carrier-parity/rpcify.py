#!/usr/bin/env python3
"""Rewrite the prod-topology-replay slice from its synthetic HTTP carrier
onto the real OTel RPC semconv keys.

The Alibaba slice was converted before perf-sentinel ingested rpc.*: every
call rides a SYNTHETIC carrier `http.url = http://<dm>/<interface>` and the
real protocol (`rpc.system` = rpctype) is a passenger attribute. Since
product 0.9.8 the ingest admits CLIENT-kind RPC spans natively, with
target "{rpc.service}/{rpc.method}" (or the span name as fallback). This
script strips the carrier and promotes the real keys, in the three shapes
verify.sh needs:

  client    drop http.url/http.method; add rpc.service=<dm> and
            rpc.method=<interface> parsed back out of the carrier url.
            The admission target "<dm>/<interface>" maps 1:1 onto the
            carrier url, so findings must be IDENTICAL to the baseline.
  fallback  drop the carrier and add NO rpc.service/rpc.method; rename the
            span to "<dm>/<interface>" so the span-name fallback resolves
            the same target. Findings must again be identical.
  server    the client shape with span.kind rewritten CLIENT->SERVER.
            The ingest kind-gate must reject every span (rpc.* is set on
            inbound handler spans too; admitting them would double-count
            each hop): zero findings expected.

rpc.system is left untouched - it carries the real rpctype (rpc/db/mc/
http/mq) and becomes the operation label. The slice is our own committed
converter output, so a span without the exact carrier shape is an infra
error and the script dies rather than skips.

usage: rpcify.py {client,fallback,server} IN OUT
"""

import argparse
import json
import sys

CARRIER = "http://"


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
                # but not an ExportTraceServiceRequest. Skip rather than crash.
                print(f"warn: skipping non-object line {lineno}", file=sys.stderr)
                continue
            yield doc


def rewrite_span(span, mode):
    attrs = span.get("attributes", [])
    url = next((a["value"]["stringValue"] for a in attrs if a.get("key") == "http.url"), None)
    if not url or not url.startswith(CARRIER) or "/" not in url[len(CARRIER):]:
        sys.exit(f"error: span {span.get('spanId')} has no 'http://<dm>/<interface>' "
                 "carrier - not a convert.py slice? Regenerate before rpcifying.")
    dm, _, interface = url[len(CARRIER):].partition("/")
    kept = [a for a in attrs if a.get("key") not in ("http.url", "http.method")]
    if mode in ("client", "server"):
        kept.append({"key": "rpc.service", "value": {"stringValue": dm}})
        kept.append({"key": "rpc.method", "value": {"stringValue": interface}})
    else:  # fallback: the span name is the only target the ingest can use
        span["name"] = f"{dm}/{interface}"
    if mode == "server":
        span["kind"] = 2  # SPAN_KIND_SERVER: the inbound handler twin
    span["attributes"] = kept
    return span


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["client", "fallback", "server"])
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    spans = lines_out = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for doc in parsed_lines(args.input):
            for rs in doc.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    for span in ss.get("spans", []):
                        rewrite_span(span, args.mode)
                        spans += 1
            out.write(json.dumps(doc, separators=(",", ":")) + "\n")
            lines_out += 1
    print(f"spans={spans} lines_out={lines_out}")


if __name__ == "__main__":
    main()
