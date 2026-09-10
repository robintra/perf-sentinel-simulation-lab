#!/usr/bin/env python3
"""Helpers over a `GET /api/findings` page, for findings-page-filters.

Sub-commands, each reading one or two JSON page dumps:

  count <page>                     rows in the page
  signatures <page>                one signature per line, in page order
  rowkeys <page>                   one "signature\tgrouping" per line, the pair
                                   the fold groups on, so a service present in
                                   two namespaces is two rows and not a
                                   duplicate
  groupings <page>                 one effective grouping value per line, sorted unique
  suggestion <page> <type>         the suggestion of the first row of that type
  compare <page-a> <page-b>        the fold A/B: same rows, same order, same
                                   group metadata. Prints the first mismatches
                                   and exits 1 on any difference.

`compare` deliberately ignores `stored_at_ms` and `first_seen_ms`: they date
the reception, and two daemons fed the same corpus receive it at different
instants. Everything the fold itself decides is compared, the representative
(`trace_id`, `severity`) included.
"""

import json
import sys

# The fold's own output: the representative it picked and the metadata it
# accumulated. A field added to the API response is not compared until it is
# named here, on purpose: silence is better than a diff of unrelated churn.
FIELDS = (
    "signature",
    "type",
    "service",
    "source_endpoint",
    "severity",
    "trace_id",
)


def load(path):
    with open(path) as stream:
        return json.load(stream)


def grouping_of(finding):
    attrs = finding.get("grouping") or []
    return attrs[0]["value"] if attrs else ""


def key(row):
    f = row["finding"]
    return tuple(f.get(name, "") for name in FIELDS) + (
        grouping_of(f),
        row.get("seen_count"),
        f.get("pattern", {}).get("template", ""),
        f.get("pattern", {}).get("occurrences"),
    )


def cmd_count(argv):
    print(len(load(argv[0])))


def cmd_signatures(argv):
    for row in load(argv[0]):
        print(row["finding"]["signature"])


def cmd_rowkeys(argv):
    for row in load(argv[0]):
        f = row["finding"]
        print("%s\t%s" % (f["signature"], grouping_of(f)))


def cmd_groupings(argv):
    print("\n".join(sorted({grouping_of(r["finding"]) for r in load(argv[0])})))


def cmd_suggestion(argv):
    for row in load(argv[0]):
        if row["finding"]["type"] == argv[1]:
            print(row["finding"]["suggestion"])
            return 0
    print("error: no %s row in %s" % (argv[1], argv[0]), file=sys.stderr)
    return 1


def cmd_compare(argv):
    a, b = load(argv[0]), load(argv[1])
    if len(a) != len(b):
        print("row count differs: %d vs %d" % (len(a), len(b)))
        return 1
    ka, kb = [key(r) for r in a], [key(r) for r in b]
    if ka == kb:
        return 0
    diffs = [(i, x, y) for i, (x, y) in enumerate(zip(ka, kb)) if x != y]
    print("%d of %d rows differ" % (len(diffs), len(ka)))
    # Set equality tells a reordering from a genuinely different fold, which
    # is the first thing to know and the two have different causes.
    print("same rows in a different order: %s" % (set(ka) == set(kb)))
    for i, x, y in diffs[:3]:
        print("  row %d" % i)
        print("    baseline: %s" % (x,))
        print("    under test: %s" % (y,))
    return 1


COMMANDS = {
    "count": cmd_count,
    "signatures": cmd_signatures,
    "rowkeys": cmd_rowkeys,
    "groupings": cmd_groupings,
    "suggestion": cmd_suggestion,
    "compare": cmd_compare,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit("usage: fold_compare.py {%s} ..." % "|".join(COMMANDS))
    sys.exit(COMMANDS[sys.argv[1]](sys.argv[2:]) or 0)
