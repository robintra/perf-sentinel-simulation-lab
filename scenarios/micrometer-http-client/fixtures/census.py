"""Census helpers for micrometer-http-client/verify.sh.

  census.py shape <otlp|zipkin|jaeger> <file>
      Prints `ok <n>` when every CLIENT span carries Micrometer's `method` and
      `status` tags and no OTel HTTP method/status key, else the offenders.
  census.py findings <analyze.json | /api/findings.json>
      One line per n_plus_one_http finding: `<template>\t<occurrences>\t<signature>`.
  census.py events <report.html>
      One line per outbound HTTP event group embedded in the report:
      `<template>\t<status_code or None>\t<count>`.
"""
import collections
import json
import sys

OTEL_KEYS = {"http.method", "http.request.method", "http.status_code", "http.response.status_code"}


def client_tags(kind, path):
    if kind == "otlp":
        for line in open(path):
            for rs in json.loads(line)["resourceSpans"]:
                for ss in rs["scopeSpans"]:
                    for s in ss["spans"]:
                        if s.get("kind") in (3, "SPAN_KIND_CLIENT"):
                            yield {a["key"]: next(iter(a["value"].values())) for a in s.get("attributes", [])}
    elif kind == "zipkin":
        for s in json.load(open(path)):
            if s.get("kind") == "CLIENT":
                yield s.get("tags", {})
    else:
        for t in json.load(open(path))["data"]:
            for s in t["spans"]:
                tags = {x["key"]: x["value"] for x in s["tags"]}
                if tags.get("span.kind") == "client":
                    yield tags


def shape(kind, path):
    spans = list(client_tags(kind, path))
    bad = [t for t in spans if "method" not in t or "status" not in t or OTEL_KEYS & t.keys()]
    print("ok %d" % len(spans) if spans and not bad else "bad %d/%d %s" % (len(bad), len(spans), bad[:2]))


def findings(path):
    doc = json.load(open(path))
    rows = doc["findings"] if isinstance(doc, dict) else doc
    for f in rows:
        f = f.get("finding", f)
        if f["type"] == "n_plus_one_http":
            print("%s\t%s\t%s" % (f["pattern"]["template"], f["pattern"]["occurrences"], f["signature"]))


def events(path):
    text, dec, i = open(path).read(), json.JSONDecoder(), 0
    counts = collections.Counter()
    while (i := text.find('{"span_id"', i)) >= 0:
        e, i = dec.raw_decode(text, i)
        if e.get("event_type") == "http_out":
            counts[(e["template"], e.get("status_code"))] += 1
    for (template, status), n in sorted(counts.items(), key=str):
        print("%s\t%s\t%d" % (template, status, n))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "shape":
        shape(sys.argv[2], sys.argv[3])
    elif mode == "findings":
        findings(sys.argv[2])
    else:
        events(sys.argv[2])
