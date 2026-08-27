#!/usr/bin/env bash
# mysql-stat: validate perf-sentinel 0.9.5's `mysql-stat` subcommand against a
# REAL MySQL LTS (9.7) performance_schema, plus the `report --mysql-stat` dashboard
# tab. Self-contained: local release binary + a throwaway MySQL container.
# No cluster.
#
# Assertions (see README.md):
#   B1  text output: 4 rankings in stable order, plausible millisecond timers
#       (picoseconds / 1e9), schema column rendered.
#   B2  --format json: rankings[3].label == "top by rows_examined".
#   B3  CSV and JSON exports of the same digest table yield the same entries.
#   B4  --traces cross-reference marks [seen in traces] on a real digest whose
#       template matches an instrumented-service query (backtick + spacing +
#       case canonicalization, exercised on genuine MySQL DIGEST_TEXT).
#   B5  robustness: NULL catch-all digest row ignored (forced via a low
#       performance_schema_digests_size), all-null export fails with a clear
#       error, NULL/\N schema rendered as absent, ANSI escape sequences in a
#       trapped export never reach the terminal (normal AND error paths).
#   B6  report --mysql-stat: mysql_stat tab + 4 ranking chips + digest data in
#       the HTML, --mysql-stat-top 0/10001/orphan rejected.
#   B7  demo --html: the demo dashboard ships a populated mysql_stat tab.
set -uo pipefail

SCENARIO="mysql-stat"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Real lab trace file whose SQL templates (dd-trace obfuscated, no backticks)
# must canonicalize onto genuine MySQL digests (backticked, spaced) for B4.
TRACES="${SCRIPT_DIR}/../datadog-bridge/fixtures/crossfmt-jaeger.json"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
# 9.7 is the current MySQL LTS line. digests_size must be small enough to
# force the NULL catch-all row in the saturation leg.
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:9.7}"
DB_MAIN="mysqlstat-db"
DB_SAT="mysqlstat-db-sat"
PW="labroot"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

cleanup() {
  docker rm -f "${DB_MAIN}" "${DB_SAT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — this scenario needs a throwaway MySQL LTS container"
[ -f "${TRACES}" ] || die "missing trace fixture ${TRACES}"

# ── helpers ─────────────────────────────────────────────────────────────────
mysql_exec() {  # $1 = container ; SQL on stdin or as $2
  if [ "$#" -ge 2 ]; then
    docker exec -e MYSQL_PWD="${PW}" "$1" mysql -uroot --batch -e "$2"
  else
    docker exec -i -e MYSQL_PWD="${PW}" "$1" mysql -uroot --batch
  fi
}

wait_mysql() {  # $1 = container
  for _ in $(seq 1 60); do
    docker exec -e MYSQL_PWD="${PW}" "$1" mysql -uroot -e "SELECT 1" >/dev/null 2>&1 && return 0
    docker ps --format '{{.Names}}' | grep -q "^$1$" \
      || { docker logs "$1" 2>&1 | tail -3; return 1; }
    sleep 2
  done
  return 1
}

# Full-table JSON export of the digest view (JSON_ARRAYAGG -> the same
# array-of-rows shape as a mysqlsh JSON export). NOT INTO OUTFILE (TSV).
export_digests_json() {  # $1 = container ; $2 = output file
  docker exec -e MYSQL_PWD="${PW}" "$1" mysql -uroot --batch --raw -N -e "
    SELECT JSON_ARRAYAGG(JSON_OBJECT(
      'SCHEMA_NAME', SCHEMA_NAME, 'DIGEST_TEXT', DIGEST_TEXT,
      'COUNT_STAR', COUNT_STAR, 'SUM_TIMER_WAIT', SUM_TIMER_WAIT,
      'AVG_TIMER_WAIT', AVG_TIMER_WAIT, 'SUM_ROWS_SENT', SUM_ROWS_SENT,
      'SUM_ROWS_EXAMINED', SUM_ROWS_EXAMINED))
    FROM performance_schema.events_statements_summary_by_digest" > "$2"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$2" \
    || die "digest JSON export is not valid JSON"
}

# CSV twin of the JSON export (client-side conversion with real quoting,
# because DIGEST_TEXT carries commas and parentheses). NULL -> empty field.
json_to_csv() {  # $1 = json in ; $2 = csv out
  python3 - "$1" "$2" <<'PY'
import csv, json, sys
cols = ["SCHEMA_NAME", "DIGEST_TEXT", "COUNT_STAR", "SUM_TIMER_WAIT",
        "AVG_TIMER_WAIT", "SUM_ROWS_SENT", "SUM_ROWS_EXAMINED"]
rows = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(cols)
    for r in rows:
        w.writerow(["" if r.get(c) is None else r.get(c) for c in cols])
PY
}

run_ms() {  # run mysql-stat; $@ = extra args; stdout->out.txt stderr->err.txt
  "${PERF_SENTINEL_LOCAL_BIN}" mysql-stat "$@" \
    > "${TMP_DIR}/out.txt" 2> "${TMP_DIR}/err.txt"
}

# ── MySQL LTS with real traffic ─────────────────────────────────────────────
step "Start MySQL ${MYSQL_IMAGE} and generate a real digest workload"
docker rm -f "${DB_MAIN}" >/dev/null 2>&1 || true
docker run -d --name "${DB_MAIN}" -e MYSQL_ROOT_PASSWORD="${PW}" \
  -e MYSQL_DATABASE=shop "${MYSQL_IMAGE}" >/dev/null || die "mysql container start failed"
wait_mysql "${DB_MAIN}" || die "MySQL never became ready"
mysql_exec "${DB_MAIN}" "SELECT @@performance_schema" | grep -q 1 \
  || die "performance_schema is OFF (must be ON by default)"

# Schema + rows sized so the aggregate full scan examines visibly more rows
# than the point lookups.
mysql_exec "${DB_MAIN}" <<'SQL'
USE shop;
CREATE TABLE orders (id INT PRIMARY KEY, status VARCHAR(16), amount INT);
CREATE TABLE line_items (id INT AUTO_INCREMENT PRIMARY KEY, order_id INT, qty INT);
CREATE TABLE users (uid INT PRIMARY KEY, name VARCHAR(32));
INSERT INTO orders SELECT seq, 'new', seq * 7 FROM (
  WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq + 1 FROM s WHERE seq < 50)
  SELECT seq FROM s) t;
INSERT INTO line_items (order_id, qty)
  SELECT (seq % 50) + 1, (seq % 5) + 1 FROM (
  WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq + 1 FROM s WHERE seq < 400)
  SELECT seq FROM s) t;
INSERT INTO users SELECT seq, CONCAT('user-', seq) FROM (
  WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq + 1 FROM s WHERE seq < 20)
  SELECT seq FROM s) t;
SQL
[ "$?" = "0" ] || die "schema seed failed"

# Reset counters so the export reflects exactly this workload, then drive a
# query mix mirroring the instrumented services' patterns: the three N+1
# lookups from the dd-trace fixtures (orders/line_items/users), an IN list,
# an UPDATE, and full-scan aggregates.
mysql_exec "${DB_MAIN}" "TRUNCATE performance_schema.events_statements_summary_by_digest" \
  || die "digest truncate failed"
python3 - <<'PY' > "${TMP_DIR}/workload.sql"
lines = ["USE shop;"]
for i in range(1, 13):
    lines.append(f"SELECT * FROM orders WHERE id = {i};")
    lines.append(f"SELECT * FROM line_items WHERE order_id = {i};")
    lines.append(f"SELECT * FROM users WHERE uid = {(i % 20) + 1};")
for i in range(1, 4):
    lines.append(f"SELECT * FROM orders WHERE id IN ({i}, {i+1}, {i+2});")
for i in range(1, 6):
    lines.append(f"UPDATE orders SET status = 'shipped' WHERE id = {i};")
for _ in range(4):
    lines.append("SELECT COUNT(*), SUM(amount) FROM orders;")
    lines.append("SELECT SUM(qty) FROM line_items;")
print("\n".join(lines))
PY
mysql_exec "${DB_MAIN}" < "${TMP_DIR}/workload.sql" >/dev/null || die "workload failed"

export_digests_json "${DB_MAIN}" "${TMP_DIR}/digests.json"
json_to_csv "${TMP_DIR}/digests.json" "${TMP_DIR}/digests.csv"
grep -q 'WHERE `id` = ?' "${TMP_DIR}/digests.csv" \
  || die "expected backticked point-lookup digest missing from the export (workload not captured?)"

# ── B1: text output, ranking order, plausible ms, schema column ────────────
step "B1: mysql-stat text output"
if run_ms --input "${TMP_DIR}/digests.csv"; then
  ORDER_OK="$(python3 - "${TMP_DIR}/out.txt" <<'PY'
import sys
out = open(sys.argv[1]).read()
labels = ["top by total_exec_time", "top by calls",
          "top by mean_exec_time", "top by rows_examined"]
pos = [out.find(l) for l in labels]
# each label exactly once: str.find keys off the FIRST hit, so a future
# summary line listing all four in order could mask out-of-order sections.
unique = all(out.count(l) == 1 for l in labels)
print(1 if all(p >= 0 for p in pos) and pos == sorted(pos) and unique else 0)
PY
)"
  if [ "${ORDER_OK}" = "1" ] && grep -q "schema:" "${TMP_DIR}/out.txt"; then
    assert_pass "B1-order" "4 rankings in stable order, schema column rendered"
  else
    assert_fail "B1-order" "ranking order or schema column wrong (see ${TMP_DIR}/out.txt)"
  fi
else
  assert_fail "B1-order" "mysql-stat exited non-zero on the real CSV export: $(tail -2 "${TMP_DIR}/err.txt")"
fi
# Millisecond plausibility from the JSON view of the SAME export: our whole
# workload is a few hundred sub-ms queries: total per digest must land in
# (0, 60000) ms. A ps->ms slip (x1e9) can't fit that window.
run_ms --input "${TMP_DIR}/digests.csv" --format json || die "mysql-stat --format json failed"
MS_CHECK="$(python3 - "${TMP_DIR}/out.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tops = d["rankings"][0]["entries"]
v = tops[0]["total_exec_time_ms"]
print("ok" if 0 < v < 60000 else f"implausible:{v}")
PY
)"
if [ "${MS_CHECK}" = "ok" ]; then
  assert_pass "B1-ms" "timer columns are plausible milliseconds (ps / 1e9)"
else
  assert_fail "B1-ms" "top total_exec_time_ms out of the plausible window: ${MS_CHECK}"
fi

step "B2: --format json ranking labels"
# Self-contained: run our own --format json rather than depending on the JSON
# residue B1-ms happens to leave in out.txt (which would silently break if B1
# is reordered or switched back to text).
run_ms --input "${TMP_DIR}/digests.csv" --format json || die "B2: mysql-stat --format json failed"
LABELS="$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print("|".join(r["label"] for r in d["rankings"]))' "${TMP_DIR}/out.txt")"
if [ "${LABELS}" = "top by total_exec_time|top by calls|top by mean_exec_time|top by rows_examined" ]; then
  assert_pass "B2" "rankings[3].label == \"top by rows_examined\" (all 4 labels exact)"
else
  assert_fail "B2" "ranking labels = [${LABELS}]"
fi

# ── B3: CSV / JSON equivalence ──────────────────────────────────────────────
step "B3: CSV and JSON exports yield the same entries"
run_ms --input "${TMP_DIR}/digests.csv" --format json && cp "${TMP_DIR}/out.txt" "${TMP_DIR}/from-csv.json"
run_ms --input "${TMP_DIR}/digests.json" --format json && cp "${TMP_DIR}/out.txt" "${TMP_DIR}/from-json.json"
EQUIV="$(python3 - "${TMP_DIR}/from-csv.json" "${TMP_DIR}/from-json.json" <<'PY'
import json, sys
def entries(p):
    d = json.load(open(p))
    return {r["label"]: [(e["normalized_template"], e["calls"]) for e in r["entries"]]
            for r in d["rankings"]}
a, b = entries(sys.argv[1]), entries(sys.argv[2])
print("ok" if a == b else "diverged")
PY
)"
if [ "${EQUIV}" = "ok" ]; then
  assert_pass "B3" "identical rankings from the CSV and JSON exports"
else
  assert_fail "B3" "CSV vs JSON rankings diverged"
fi

# ── B4: --traces cross-reference on a real digest ───────────────────────────
step "B4: [seen in traces] via canonicalized matching on genuine DIGEST_TEXT"
if run_ms --input "${TMP_DIR}/digests.csv" --traces "${TRACES}"; then
  # The dd-trace fixture templates carry no backticks and tight spacing. The
  # MySQL digests are backticked and spaced: a marker on one of the three
  # N+1 templates proves the canonicalization, on real data on both sides.
  if grep 'seen in traces' "${TMP_DIR}/out.txt" | grep -Eq 'orders|line_items|users'; then
    assert_pass "B4" "[seen in traces] set on a real backticked digest matching the lab trace templates"
  else
    assert_fail "B4" "no [seen in traces] marker on orders/line_items/users digests"
  fi
else
  assert_fail "B4" "mysql-stat --traces exited non-zero: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# ── B5: robustness on real exports ──────────────────────────────────────────
step "B4-grouping: a split-by-tenant workload is still marked as traced"
python3 - "${TRACES}" "${TMP_DIR}" <<'PY'
import json, pathlib, sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
counts = {}
for trace in data["data"]:
    for span in trace["spans"]:
        statement = next((tag["value"] for tag in span.get("tags", []) if tag["key"] == "db.statement"), None)
        if not statement:
            continue
        template = statement.rsplit("=", 1)[0]
        index = counts.get(template, 0)
        counts[template] = index + 1
        span.setdefault("tags", []).append({"key": "tenant.id", "type": "string", "value": "tenant-a" if index % 2 == 0 else "tenant-b"})
out = pathlib.Path(sys.argv[2])
(out / "grouping-traces.json").write_text(json.dumps(data))
(out / "grouping.toml").write_text('[detection]\ngrouping_attributes = ["tenant.id"]\n')
PY
if run_ms --input "${TMP_DIR}/digests.csv" --traces "${TMP_DIR}/grouping-traces.json" \
     --config "${TMP_DIR}/grouping.toml" --format json \
   && python3 - "${TMP_DIR}/out.txt" <<'PY'
import json, sys

report = json.load(open(sys.argv[1]))
marked = {entry["normalized_template"]: entry["seen_in_traces"]
          for ranking in report["rankings"] for entry in ranking["entries"]}
# The three point lookups the trace fixture actually issues. Splitting the
# workload across two tenants drops every group below the N+1 threshold, so no
# detector fires on any of them. Before 0.15.0 the cross-reference keyed on the
# findings, which left a perfectly healthy traced query unmarked; it now keys on
# every template the traces carried, so the marker is there because the query is
# traced, not because it is broken. Naming them beats a substring filter, which
# also swept in the aggregates and the UPDATE below.
traced = [
    "SELECT * FROM `orders` WHERE `id` = ?",
    "SELECT * FROM `line_items` WHERE `order_id` = ?",
    "SELECT * FROM `users` WHERE `uid` = ?",
]
for template in traced:
    assert marked.get(template) is True, f"traced template unmarked: {template!r}"
# The counterpart: digest rows the traces never carried must stay unmarked, or
# the cross-reference is matching on something looser than the template.
for template in ("SELECT SUM ( `qty` ) FROM `line_items`",
                 "UPDATE `orders` SET STATUS = ? WHERE `id` = ?"):
    assert marked.get(template) is False, f"untraced template marked: {template!r}"
summary = report.get("trace_match")
assert summary and summary["matched_templates"] == len(traced), \
    f"trace_match should count {len(traced)} matched templates: {summary}"
PY
then
  assert_pass "B4-grouping" "grouped traffic still marks its templates, and trace_match counts them"
else
  assert_fail "B4-grouping" "a traced template went unmarked under a tenant grouping"
fi

step "B5: NULL catch-all row (saturated digest table)"
docker rm -f "${DB_SAT}" >/dev/null 2>&1 || true
docker run -d --name "${DB_SAT}" -e MYSQL_ROOT_PASSWORD="${PW}" \
  "${MYSQL_IMAGE}" --performance-schema-digests-size=10 >/dev/null \
  || die "saturated mysql container start failed"
wait_mysql "${DB_SAT}" || die "saturated MySQL never became ready"
# 40 structurally distinct statements against a 10-slot digest table forces
# the DIGEST_TEXT = NULL catch-all row. No default schema -> SCHEMA_NAME NULL
# rows are real here too.
python3 -c "print('\n'.join(f'SELECT 1 AS alias_{i};' for i in range(40)))" \
  | mysql_exec "${DB_SAT}" >/dev/null || die "saturation workload failed"
export_digests_json "${DB_SAT}" "${TMP_DIR}/sat.json"
python3 -c '
import json,sys
rows = json.load(open(sys.argv[1]))
assert any(r["DIGEST_TEXT"] is None for r in rows), "no NULL catch-all row — precondition failed"
' "${TMP_DIR}/sat.json" || die "saturation did not produce the NULL catch-all row"
if run_ms --input "${TMP_DIR}/sat.json" --format json \
   && python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
entries = [e for r in d["rankings"] for e in r["entries"]]
# Rankings non-empty AND the NULL catch-all row is actually excluded: were it
# ranked, its entry would carry an empty/null template. A bare non-emptiness
# check would greenlight a regression that surfaces the NULL row as a hotspot.
ok = bool(entries) and all(e.get("normalized_template") for e in entries)
sys.exit(0 if ok else 1)' "${TMP_DIR}/out.txt"; then
  assert_pass "B5-catchall" "NULL catch-all digest row excluded, remaining entries ranked (no empty-template hotspot)"
else
  assert_fail "B5-catchall" "saturated export: NULL catch-all row ranked or mysql-stat broke"
fi

step "B5: all-null export fails with a clear error"
python3 -c '
import json,sys
rows = json.load(open(sys.argv[1]))
for r in rows: r["DIGEST_TEXT"] = None
json.dump(rows, open(sys.argv[2], "w"))' "${TMP_DIR}/digests.json" "${TMP_DIR}/all-null.json"
if run_ms --input "${TMP_DIR}/all-null.json"; then
  assert_fail "B5-allnull" "all-null export exited 0 (expected a hard error)"
elif grep -q "DIGEST_TEXT" "${TMP_DIR}/err.txt"; then
  assert_pass "B5-allnull" "clear error naming DIGEST_TEXT: $(tr -d '\n' < "${TMP_DIR}/err.txt" | tail -c 120)"
else
  assert_fail "B5-allnull" "exit 1 but the error does not explain the cause: $(tail -2 "${TMP_DIR}/err.txt")"
fi

step "B5: NULL / \\N schema rendered as absent"
# \N is how mysql batch mode spells NULL: a real-world CSV artifact.
python3 - "${TMP_DIR}/digests.csv" "${TMP_DIR}/schema-null.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1])))
for i, r in enumerate(rows[1:], 1):
    r[0] = "\\N" if i % 2 else "NULL"
csv.writer(open(sys.argv[2], "w", newline="")).writerows(rows)
PY
if run_ms --input "${TMP_DIR}/schema-null.csv" \
   && ! grep -Eq 'schema: *(NULL|\\N)' "${TMP_DIR}/out.txt"; then
  assert_pass "B5-schema" "NULL/\\N schema never rendered as a literal"
else
  assert_fail "B5-schema" "literal NULL/\\N leaked as a schema name (or run failed)"
fi

step "B5: ANSI escape sequences never reach the terminal"
python3 - "${TMP_DIR}/digests.csv" "${TMP_DIR}/ansi.csv" "${TMP_DIR}/ansi-err.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1])))
evil = "\x1b]0;pwned\x07"
rows[1][1] = f"SELECT {evil} FROM `orders` WHERE `id` = ?"
rows[2][0] = f"shop{evil}"
csv.writer(open(sys.argv[2], "w", newline="")).writerows(rows)
# error path: a poisoned numeric field must surface a SANITIZED parse error
bad = [r[:] for r in rows]
bad[1][2] = f"12{evil}x"
csv.writer(open(sys.argv[3], "w", newline="")).writerows(bad)
PY
# Scan for the ATTACKER-CONTROLLED bytes (the OSC introducer ESC-] and BEL),
# not any ESC: the tracing logger legitimately writes its own CSI color codes
# to stderr, which are not data.
ansi_leak() { LC_ALL=C grep -q $'\x1b\x5d' "$@" || LC_ALL=C grep -q $'\x07' "$@"; }
run_ms --input "${TMP_DIR}/ansi.csv"
NORMAL_RC=$?
NORMAL_CLEAN=1
ansi_leak "${TMP_DIR}/out.txt" "${TMP_DIR}/err.txt" && NORMAL_CLEAN=0
run_ms --input "${TMP_DIR}/ansi-err.csv"
ERR_RC=$?
ERR_CLEAN=1
ansi_leak "${TMP_DIR}/out.txt" "${TMP_DIR}/err.txt" && ERR_CLEAN=0
if [ "${NORMAL_RC}" = "0" ] && [ "${NORMAL_CLEAN}" = "1" ] \
   && [ "${ERR_RC}" != "0" ] && [ "${ERR_CLEAN}" = "1" ]; then
  assert_pass "B5-ansi" "no raw ESC byte in normal output nor in parse-error messages"
else
  assert_fail "B5-ansi" "ANSI handling: normal rc=${NORMAL_RC} clean=${NORMAL_CLEAN}, error rc=${ERR_RC} clean=${ERR_CLEAN}"
fi

step "B6: report --mysql-stat HTML tab + flag validation"
if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${TRACES}" \
     --mysql-stat "${TMP_DIR}/digests.csv" --output "${TMP_DIR}/r.html" \
     > /dev/null 2> "${TMP_DIR}/err.txt" && [ -s "${TMP_DIR}/r.html" ]; then
  CHIPS=0
  for l in "top by total_exec_time" "top by calls" "top by mean_exec_time" "top by rows_examined"; do
    grep -q "$l" "${TMP_DIR}/r.html" && CHIPS=$((CHIPS + 1))
  done
  if grep -q "mysql_stat" "${TMP_DIR}/r.html" && [ "${CHIPS}" = "4" ] \
     && grep -q "line_items" "${TMP_DIR}/r.html"; then
    assert_pass "B6-html" "mysql_stat tab with 4 ranking chips and real digest data"
  else
    assert_fail "B6-html" "mysql_stat tab incomplete (chips=${CHIPS}/4)"
  fi
else
  assert_fail "B6-html" "report --mysql-stat failed: $(tail -2 "${TMP_DIR}/err.txt")"
fi
FLAGS_OK=1
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${TRACES}" --mysql-stat "${TMP_DIR}/digests.csv" \
  --mysql-stat-top 0 --output "${TMP_DIR}/x.html" >/dev/null 2>&1 && FLAGS_OK=0
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${TRACES}" --mysql-stat "${TMP_DIR}/digests.csv" \
  --mysql-stat-top 10001 --output "${TMP_DIR}/x.html" >/dev/null 2>&1 && FLAGS_OK=0
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${TRACES}" \
  --mysql-stat-top 5 --output "${TMP_DIR}/x.html" >/dev/null 2>"${TMP_DIR}/orphan.err" && FLAGS_OK=0
# What matters is that the message names the required COMPANION flag, not just
# the offending `--mysql-stat-top` whose own name contains "mysql-stat". The
# space after `--mysql-stat` is what separates the two. Both spellings count:
# clap's own `--mysql-stat <FILE>`, and the custom message the CLI emits since
# `--mysql-stat-prometheus` gave the flag a second companion.
if [ "${FLAGS_OK}" = "1" ] && grep -qE -- "--mysql-stat (<|or)" "${TMP_DIR}/orphan.err"; then
  assert_pass "B6-flags" "--mysql-stat-top 0 / 10001 / orphan all rejected with a pointer to the companion flag"
else
  assert_fail "B6-flags" "flag validation gap (ok=${FLAGS_OK}, orphan msg: $(tail -1 "${TMP_DIR}/orphan.err" 2>/dev/null))"
fi

# ── B7: demo dashboard ──────────────────────────────────────────────────────
step "B7: demo --html ships a populated mysql_stat tab"
if "${PERF_SENTINEL_LOCAL_BIN}" demo --html "${TMP_DIR}/demo.html" >/dev/null 2>&1 \
   && grep -q "mysql_stat" "${TMP_DIR}/demo.html" \
   && grep -q "top by rows_examined" "${TMP_DIR}/demo.html" \
   && grep -q 'rows_examined":' "${TMP_DIR}/demo.html"; then
  # `rows_examined":` is the mysql_stat entry JSON field (MySQL-only; pg_stat
  # uses rows/shared_blks) present on every data row, absent from the empty
  # scaffold and from the `top by rows_examined` chip label (no colon there).
  assert_pass "B7" "demo dashboard mysql_stat tab present and populated (real digest rows)"
else
  assert_fail "B7" "demo dashboard mysql_stat tab missing or empty"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel 0.9.5 mysql-stat against a real MySQL LTS (9.7) performance_schema."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
