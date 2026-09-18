#!/usr/bin/env python3
"""Send ONE trace whose spans are stamped at a chosen wall-clock time.

tracegen stamps every trace from a constant base, which is what a load run
wants and what a scenario about event time cannot use: the 0.23.0
correlator pairs findings on their own timestamps and the daemon's slow
window counts episodes across analysis batches, so a scenario has to place
each trace in time and in its own batch. This is that one-shot sender.

Shapes (same span builders as tracegen, so the daemon sees the same I/O):
  n_plus_one  one root + 8 SELECTs on one table, fresh parameter each
  slow_one    one root + a single 850 ms SELECT, below any per-batch
              slow_query_min_occurrences on its own

The template is fixed by --table, so every send of one service lands on the
same finding endpoint. Prints the trace id in hex on stdout.

  emit_at.py --endpoint http://127.0.0.1:4318 --service svc-a \
             --shape n_plus_one --offset-ms -5000 --trace-num 7
"""

import argparse
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import templates  # noqa: E402
from tracegen import HttpPbSender, to_otlp_request  # noqa: E402


def build(shape, base_ns, table, seed):
    ctx = {"rng": random.Random(seed), "base_ns": base_ns}
    route = "/api/orders/{id}"
    spans = [templates._root(ctx, route, duration_ms=1200)]
    if shape == "n_plus_one":
        for i in range(8):
            stmt = "SELECT * FROM %s WHERE parent_id = %d" % (table, ctx["rng"].randint(1000, 99999))
            spans.append(templates._sql(ctx, i + 2, 1, 2 + i * 4, stmt))
    else:
        stmt = "SELECT * FROM %s ORDER BY created_at DESC LIMIT 50" % table
        spans.append(templates._sql(ctx, 2, 1, 5, stmt, duration_ms=850))
    return spans


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--shape", choices=["n_plus_one", "slow_one"], required=True)
    p.add_argument("--table", default="orders")
    p.add_argument("--offset-ms", type=int, default=0, help="event time relative to now")
    p.add_argument("--at-ms", type=int, help="absolute event time, epoch ms (wins over --offset-ms)")
    p.add_argument("--trace-num", type=int, required=True)
    p.add_argument("--resource-attribute", action="append", default=[], metavar="KEY=VALUE")
    a = p.parse_args()
    base_ns = a.at_ms * templates.MS if a.at_ms is not None else time.time_ns() + a.offset_ms * templates.MS
    spans = build(a.shape, base_ns, a.table, a.trace_num)
    attrs = [tuple(kv.split("=", 1)) for kv in a.resource_attribute]
    body = to_otlp_request([(a.trace_num, a.service, spans)], 0, attrs).SerializeToString()
    HttpPbSender(a.endpoint).send_raw(body)
    print(a.trace_num.to_bytes(16, "big").hex())


if __name__ == "__main__":
    main()
