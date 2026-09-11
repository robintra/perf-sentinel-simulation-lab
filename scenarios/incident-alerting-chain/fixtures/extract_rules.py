"""Extract spec.groups from a PrometheusRule or VMRule into a plain rule file.

Both CRD flavours keep their groups at the same path, which is what lets one
promtool run cover a rule and its twin.

Usage: extract_rules.py <source.yaml> <destination.yaml> <kind>
"""
import sys

import yaml

src, dst, kind = sys.argv[1:4]
for doc in yaml.safe_load_all(open(src)):
    if doc and doc.get("kind") == kind:
        yaml.safe_dump({"groups": doc["spec"]["groups"]}, open(dst, "w"), sort_keys=False)
        sys.exit(0)
sys.exit("no %s document in %s" % (kind, src))
