"""Census helpers for hibernate-alias-suggestion/verify.sh.

  census.py findings <analyze.json | /api/findings.json>
      One line per finding of the fixture's five loops:
      `<loop>\t<framework>\t<signature>\t<hibernate scope>\t<code location>\t<comment>`
      where <loop> is lazy, jdbc, derived, update or http, and the last three
      columns are yes/no.
  census.py micrometer <otlp.ndjson>
      Prints `ok <n>` when every span sits under the `org.springframework.boot`
      scope, none carries `code.namespace` and none is a database span, else
      what breaks that premise.
"""
import json
import sys

# Template fragment -> loop, most specific first.
LOOPS = [
    ("where b1_0.author_id=?", "lazy"),
    ("from book where author_id = ?", "jdbc"),
    ("where b1_0.title=?", "derived"),
    ("update book b1_0 set title=?", "update"),
    ("localhost/api/ping/{id}", "http"),
]
DETECTORS = {"n_plus_one_sql", "redundant_sql", "n_plus_one_http"}


def yes(flag):
    return "yes" if flag else "no"


def findings(path):
    doc = json.load(open(path))
    rows = doc["findings"] if isinstance(doc, dict) else doc
    out = []
    for f in rows:
        f = f.get("finding", f)
        if f["type"] not in DETECTORS:
            continue
        template = f["pattern"]["template"]
        loop = next((name for frag, name in LOOPS if frag in template), None)
        if loop is None:
            continue
        scopes = f.get("instrumentation_scopes") or []
        fix = f.get("suggested_fix") or {}
        out.append("\t".join([
            loop,
            str(fix.get("framework")),
            f["signature"],
            yes(any("hibernate" in s or "spring-data" in s for s in scopes)),
            yes(f.get("code_location")),
            yes(template.lstrip().startswith("/*")),
        ]))
    print("\n".join(sorted(out)))


def micrometer(path):
    n, bad = 0, []
    for line in open(path):
        for rs in json.loads(line)["resourceSpans"]:
            for ss in rs["scopeSpans"]:
                scope = ss.get("scope", {}).get("name")
                for s in ss["spans"]:
                    n += 1
                    keys = {a["key"] for a in s.get("attributes", [])}
                    if scope != "org.springframework.boot":
                        bad.append("scope %s" % scope)
                    if "code.namespace" in keys:
                        bad.append("code.namespace on %s" % s["name"])
                    if any(k.startswith("db.") for k in keys):
                        bad.append("db span %s" % s["name"])
    print("ok %d" % n if n and not bad else "bad %d/%d %s" % (len(bad), n, bad[:3]))


if __name__ == "__main__":
    {"findings": findings, "micrometer": micrometer}[sys.argv[1]](sys.argv[2])
