#!/usr/bin/env python3
# Generate the native perf-sentinel SpanEvent fixtures for the
# sql-backtick-redaction scenario (0.9.2 normalize/sql.rs changes).
#
# Two files, each a JSON array of native SpanEvent objects (the shape
# `analyze --input` auto-detects). The native batch path normalizes the
# `target` SQL, so these fixtures exercise normalize/sql.rs directly with
# NO cluster and NO daemon.
#
#   backtick.native.json
#     One trace, six SQL children sharing ONE normalized template but
#     differing in the bound `id` literal (1..6) -> a real N+1 group
#     (distinct_params >= n_plus_one_min_occurrences=5, mode-independent).
#     Asserts MySQL backtick identifiers are preserved. The table name is
#     the NUMERIC identifier `2024` (a year-partitioned table): without the
#     0.9.2 InBacktick tokenizer state the 2024 between backticks would be
#     extracted as a numeric literal and masked to `?`, so this column is
#     the real discriminator. `col2` additionally guards alphanumeric ids.
#
#   array-redaction.native.json
#     One trace, six SQL children. The PostgreSQL array/subscript string
#     literals ARRAY['secret','pii'] and data['ssn'] must be MASKED to ?
#     in the normalized template (the most important 0.9.2 security fix):
#     no string literal may leak into analyze output. A distinct owner id
#     (1..6) makes the group an N+1 so a finding is guaranteed to fire and
#     carry the masked pattern.template.
#
# stdlib-only. Regenerating needs no extra packages. verify.sh consumes the
# committed *.native.json directly and never runs this generator.
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_NS = 1_749_297_600_000_000_000


def iso_ts(ns):
    # mirrors tracegen.iso_ts (UTC, millisecond precision, trailing Z)
    import datetime

    dt = datetime.datetime.fromtimestamp(ns / 1e9, tz=datetime.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ns // 1_000_000 % 1000)


def sql_event(trace_hex, sid, parent_sid, offset_ms, statement, endpoint, duration_us=2000):
    start = BASE_NS + offset_ms * 1_000_000
    return {
        "timestamp": iso_ts(start),
        "trace_id": "t%032x" % trace_hex,
        "span_id": "s%016x" % ((trace_hex << 20) | sid),
        "parent_span_id": "s%016x" % ((trace_hex << 20) | parent_sid),
        "service": "shop-mysql",
        "cloud_region": "eu-west-3",
        "type": "sql",
        "operation": statement.split(None, 1)[0].upper(),
        "target": statement,
        "duration_us": duration_us,
        "source": {"endpoint": endpoint, "method": "Handler::handle"},
    }


def build_backtick():
    # MySQL backtick identifiers, one per id 1..6. `col2` carries an internal
    # digit that must survive (not be tokenized as the literal 2).
    events = []
    for i in range(1, 7):
        stmt = "SELECT `name`, `col2` FROM `2024` WHERE `id` = %d" % i
        events.append(sql_event(0xB1, i + 1, 1, 2 + i * 4, stmt, "GET /api/users/{id}"))
    return events


def build_array_redaction():
    # PostgreSQL array + subscript string literals. They MUST be masked.
    # owner id 1..6 -> distinct params -> guaranteed N+1 finding.
    events = []
    for i in range(1, 7):
        stmt = (
            "SELECT * FROM t WHERE owner = %d "
            "AND tags = ARRAY['secret', 'pii'] AND data['ssn'] IS NOT NULL" % i
        )
        events.append(sql_event(0xA2, i + 1, 1, 2 + i * 4, stmt, "GET /api/audit"))
    return events


def main():
    for name, events in (
        ("backtick.native.json", build_backtick()),
        ("array-redaction.native.json", build_array_redaction()),
    ):
        path = os.path.join(HERE, name)
        with open(path, "w") as fh:
            json.dump(events, fh, indent=2)
            fh.write("\n")
        print("%s  %d events" % (name, len(events)))


if __name__ == "__main__":
    main()
