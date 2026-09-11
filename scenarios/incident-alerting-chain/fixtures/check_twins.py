"""Assert the prometheus-operator and VictoriaMetrics files carry the same rules.

The twin is maintained by hand. A drift means every proof taken on one file
covers one operator and silently not the other, which is the whole reason the
rule unit tests can be run once instead of twice.

Usage: check_twins.py <prom-rules.yaml> <vm-rules.yaml>
"""
import sys

import yaml

FIELDS = ("expr", "for", "labels", "annotations")


def rules(path):
    out = {}
    for group in yaml.safe_load(open(path))["groups"]:
        for rule in group.get("rules", []):
            out[rule["alert"]] = {
                # Whitespace is layout, not meaning: the two files wrap their
                # expressions differently and that is not a drift.
                "expr": " ".join(rule["expr"].split()),
                "for": rule.get("for"),
                "labels": rule.get("labels"),
                "annotations": rule.get("annotations"),
            }
    return out


a, b = rules(sys.argv[1]), rules(sys.argv[2])
if set(a) != set(b):
    sys.exit("alert names differ: %s" % sorted(set(a) ^ set(b)))
for name in sorted(a):
    for field in FIELDS:
        if a[name][field] != b[name][field]:
            sys.exit("%s.%s differs:\n  prom: %s\n  vm:   %s"
                     % (name, field, a[name][field], b[name][field]))
print("%d rules identical: %s" % (len(a), ", ".join(sorted(a))))
