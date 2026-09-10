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
  compare <page-a> <page-b>        the fold A/B: the same rows carrying the
                                   same group metadata, batch by batch, in the
                                   same batch order. Prints the first
                                   mismatches and exits 1 on any difference.

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


def batches(rows):
    """The page split into runs of equal `stored_at_ms`, in page order.

    One analysis batch stamps every finding it produces with one instant, so
    `stored_at_ms` identifies the batch. The listing's documented order is
    newest first on that stamp; *within* one batch the order is the order of
    insertion, which the detectors do not fix and which moves from run to
    run on the same binary. Comparing the two pages position by position
    therefore fails on a reordering the contract never promised, so the
    comparison is per batch: the sequence of batches is compared in order,
    and the rows inside one batch as a set.
    """
    out = []
    for row in rows:
        stamp = row.get("stored_at_ms")
        if not out or out[-1][0] != stamp:
            out.append((stamp, []))
        out[-1][1].append(key(row))
    return out


def cmd_compare(argv):
    a, b = load(argv[0]), load(argv[1])
    if len(a) != len(b):
        print("row count differs: %d vs %d" % (len(a), len(b)))
        return 1
    ka, kb = [key(r) for r in a], [key(r) for r in b]
    ba, bb = batches(a), batches(b)

    # Newest first, the half of the order that IS a contract. Checked on each
    # side on its own, since the two daemons received the corpus at different
    # instants and the stamps themselves never match.
    for name, blocks in (("baseline", ba), ("under test", bb)):
        stamps = [s for s, _ in blocks]
        if stamps != sorted(stamps, reverse=True):
            print("%s: the listing is not newest-first on stored_at_ms" % name)
            return 1

    if len(ba) != len(bb):
        print("batch count differs: %d vs %d" % (len(ba), len(bb)))
        return 1
    problems = []
    for i, ((_, rows_a), (_, rows_b)) in enumerate(zip(ba, bb)):
        if set(rows_a) != set(rows_b):
            problems.append((i, set(rows_a) - set(rows_b), set(rows_b) - set(rows_a)))
    if not problems:
        if ka != kb:
            moved = sum(1 for x, y in zip(ka, kb) if x != y)
            print("%d row(s) sit in a different order inside their batch, "
                  "which the listing does not order; every batch holds the "
                  "same rows" % moved)
        return 0
    print("%d of %d batches hold different rows" % (len(problems), len(ba)))
    for i, only_a, only_b in problems[:3]:
        print("  batch %d" % i)
        for row in list(only_a)[:2]:
            print("    baseline only: %s" % (row,))
        for row in list(only_b)[:2]:
            print("    under test only: %s" % (row,))
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
