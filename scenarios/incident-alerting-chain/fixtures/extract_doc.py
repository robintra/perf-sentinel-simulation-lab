"""Write one document of a multi-document YAML file out on its own, verbatim.

Used to apply the shipped PrometheusRule without touching a byte of it. The
scenario's victim names its container `app` so that this is possible: an
adapted copy would only ever validate the copy.

Usage: extract_doc.py <source.yaml> <kind> <destination.yaml>
"""
import sys

import yaml

src, kind, dst = sys.argv[1:4]
for doc in yaml.safe_load_all(open(src)):
    if doc and doc.get("kind") == kind:
        yaml.safe_dump(doc, open(dst, "w"), sort_keys=False)
        sys.exit(0)
sys.exit("no %s document in %s" % (kind, src))
