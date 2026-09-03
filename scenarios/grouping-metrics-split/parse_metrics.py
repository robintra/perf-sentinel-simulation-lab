"""Read a Prometheus text exposition and answer the questions this scenario asks.

Kept out of verify.sh because every leg needs the same parser: series of one
family keyed by their label set, and the same series folded over `grouping`,
which is what `sum by (service)` means in PromQL.

Usage: parse_metrics.py <mode> <file> [args...]

  arity    <file> <family>               label names of the family, sorted, one per line
  series   <file> <family>               "<labels> <value>" per series, sorted
  sumsvc   <file> <family>               same, summed over grouping (PromQL sum by(service))
  total    <file> <family>               the family's grand total (PromQL sum())
  groupings <file> <family>              distinct grouping values, one per line
  services <file> <family>               distinct service values, one per line
  pairs    <file> <family>               distinct "service<TAB>grouping" pairs, one per line
  value    <file> <family>               a single unlabelled sample's value
"""

import collections
import re
import sys

SAMPLE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})? ([0-9.eE+-]+|NaN)$")
# The histogram's samples carry the family name plus a suffix, and `le`
# partitions buckets rather than identifying a series.
HISTOGRAM_SUFFIXES = ("_bucket", "_sum", "_count")


def labels_of(raw):
    return dict(re.findall(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"', raw or ""))


def read(path, family):
    """Yield (labels, value) of every sample of `family`, `le` dropped."""
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        matched = SAMPLE.match(line)
        if not matched:
            continue
        name, raw, value = matched.groups()
        if name != family and not (
            name.startswith(family) and name[len(family):] in HISTOGRAM_SUFFIXES
        ):
            continue
        labels = labels_of(raw)
        labels.pop("le", None)
        # A histogram's _bucket samples repeat one series once per bucket, so
        # only the _count sample is read for the histogram families: the
        # others would multiply every series by 12.
        if name.endswith(("_bucket", "_sum")):
            continue
        yield labels, float(value)


def keyed(path, family, drop=()):
    out = collections.Counter()
    for labels, value in read(path, family):
        key = tuple(sorted((k, v) for k, v in labels.items() if k not in drop))
        out[key] += value
    return out


def render(counter):
    for key, value in sorted(counter.items()):
        rendered = ",".join(f'{k}="{v}"' for k, v in key)
        # %g would round large counters; the values compared here are integers
        # or exact halves, so repr of the float is both stable and readable.
        print(f"{{{rendered}}} {value!r}")


def main():
    mode, path, family = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == "arity":
        names = {k for labels, _ in read(path, family) for k in labels}
        print("\n".join(sorted(names)))
    elif mode == "series":
        render(keyed(path, family))
    elif mode == "sumsvc":
        render(keyed(path, family, drop=("grouping",)))
    elif mode == "total":
        print(repr(sum(keyed(path, family).values())))
    elif mode in ("groupings", "services"):
        want = mode[:-1]
        print("\n".join(sorted({labels.get(want, "") for labels, _ in read(path, family)})))
    elif mode == "pairs":
        # What the caps actually bound: (service, grouping), not either axis on
        # its own. Deduplicated across the type/severity labels that multiply a
        # pair into several series.
        seen = {
            (labels.get("service", ""), labels.get("grouping", ""))
            for labels, _ in read(path, family)
        }
        print("\n".join(f"{s}\t{g}" for s, g in sorted(seen)))
    elif mode == "value":
        values = [v for labels, v in read(path, family) if not labels]
        print(repr(values[0]) if values else "")
    else:
        sys.exit(f"unknown mode {mode}")


if __name__ == "__main__":
    main()
