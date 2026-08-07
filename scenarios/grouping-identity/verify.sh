#!/usr/bin/env bash
# perf-sentinel 0.11 grouping contract across real ingestion boundaries.

set -uo pipefail

SCENARIO="grouping-identity"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
TRACEGEN="${LAB_ROOT}/tools/tracegen/tracegen.py"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
TMP_DIR="/tmp/${SCENARIO}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
DAEMON_HTTP_PORT="${GROUPING_DAEMON_HTTP_PORT:-14518}"
DAEMON_GRPC_PORT="${GROUPING_DAEMON_GRPC_PORT:-14517}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
SOCK="/tmp/ps-grouping-$$.sock"
TRACEGEN_IMAGE="${TRACEGEN_IMAGE:-lab-tracegen:grouping}"
DAEMON_PID=""

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/prod" "${TMP_DIR}/staging"

color_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
color_green() { printf '\033[32m%s\033[0m\n' "$*"; }
color_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red "    error: $*"; exit 1; }

cleanup() {
  if [ -n "${DAEMON_PID}" ]; then
    kill "${DAEMON_PID}" 2>/dev/null || true
    wait "${DAEMON_PID}" 2>/dev/null || true
  fi
  rm -f "${SOCK}" 2>/dev/null || true
}
trap cleanup EXIT

FAILURES=0
declare -a RESULTS=()
pass() { ok "$2"; RESULTS+=("$1|PASS|$2"); }
fail() { color_red "    FAIL: $2"; RESULTS+=("$1|FAIL|$2"); FAILURES=$((FAILURES + 1)); }

analyze() {  # input, config, output, stderr
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$1" --config "$2" \
    --no-acknowledgments --format json >"$3" 2>"$4"
}

step "0. Pre-flight"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN}"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"
VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
[ "${VERSION}" = "0.11.0" ] || die "expected perf-sentinel 0.11.0, got ${VERSION}"
PRODUCT_COMMIT="$(git -C "${PERF_SENTINEL_REPO_PATH}" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
ok "perf-sentinel ${VERSION} (${PRODUCT_COMMIT})"

step "A. tracegen emits ordered resource and span attributes"
gen_group() {  # directory, namespace, tenant
  python3 "${TRACEGEN}" \
    --protocol dump-native --traces 1 --services 1 \
    --service-prefix grouping --run-nonce contract --mix n_plus_one:1 \
    --resource-attribute "k8s.namespace.name=$2" \
    --resource-attribute service.namespace=commerce \
    --span-attribute "tenant.id=$3" \
    --out "$1" >"$1/tracegen.json"
}
gen_group "${TMP_DIR}/prod" prod-eu tenant-a || die "tracegen prod fixture failed"
gen_group "${TMP_DIR}/staging" staging-eu tenant-b || die "tracegen staging fixture failed"

python3 - "${TMP_DIR}/prod/shard-00.native.json" <<'PY' || die "tracegen grouping contract failed"
import json, sys
events = json.load(open(sys.argv[1], encoding="utf-8"))
expected = [
    {"key": "k8s.namespace.name", "value": "prod-eu"},
    {"key": "service.namespace", "value": "commerce"},
    {"key": "tenant.id", "value": "tenant-a"},
]
assert events and all(event.get("grouping") == expected for event in events)
PY
pass "A" "tracegen preserves resource-first ordering and span attributes"

python3 - "${TMP_DIR}/prod/shard-00.native.json" \
  "${TMP_DIR}/staging/shard-00.native.json" "${TMP_DIR}/two-groups.native.json" <<'PY'
import json, sys
prod = json.load(open(sys.argv[1], encoding="utf-8"))
staging = json.load(open(sys.argv[2], encoding="utf-8"))
for event in staging:
    event["trace_id"] = "staging-" + event["trace_id"]
    event["span_id"] = "staging-" + event["span_id"]
    if event.get("parent_span_id"):
        event["parent_span_id"] = "staging-" + event["parent_span_id"]
json.dump(prod + staging, open(sys.argv[3], "w", encoding="utf-8"), separators=(",", ":"))
PY

cat >"${TMP_DIR}/default.toml" <<'EOF'
[detection]
n_plus_one_min_occurrences = 5
grouping_attributes = ["k8s.namespace.name", "service.namespace"]
EOF
cat >"${TMP_DIR}/tenant.toml" <<'EOF'
[detection]
n_plus_one_min_occurrences = 5
grouping_attributes = ["tenant.id"]
EOF

step "B. default grouping separates the same service"
analyze "${TMP_DIR}/two-groups.native.json" "${TMP_DIR}/default.toml" \
  "${TMP_DIR}/default.json" "${TMP_DIR}/default.err" || fail "B" "analyze failed: $(tail -1 "${TMP_DIR}/default.err")"
if python3 - "${TMP_DIR}/default.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
findings = [f for f in d.get("findings", []) if f.get("type") == "n_plus_one_sql"]
assert len(findings) == 2, len(findings)
assert len({f["service"] for f in findings}) == 1
assert {f["grouping"][0]["value"] for f in findings} == {"prod-eu", "staging-eu"}
assert all(f["grouping"][0]["key"] == "k8s.namespace.name" for f in findings)
assert all("service_namespace" not in f and "k8s_namespace" not in f for f in findings)
PY
then pass "B" "two deployments remain two findings with the 0.11 JSON contract"
else fail "B" "default grouping did not keep prod-eu and staging-eu separate"
fi

step "C. a span-level tenant attribute overrides namespace identity"
analyze "${TMP_DIR}/two-groups.native.json" "${TMP_DIR}/tenant.toml" \
  "${TMP_DIR}/tenant.json" "${TMP_DIR}/tenant.err" || fail "C" "analyze failed: $(tail -1 "${TMP_DIR}/tenant.err")"
if python3 - "${TMP_DIR}/tenant.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
findings = [f for f in d.get("findings", []) if f.get("type") == "n_plus_one_sql"]
assert len(findings) == 2
assert {f["grouping"][0]["value"] for f in findings} == {"tenant-a", "tenant-b"}
assert all(f["grouping"] == [{"key": "tenant.id", "value": f["grouping"][0]["value"]}] for f in findings)
PY
then pass "C" "custom tenant.id grouping follows span data, not namespace"
else fail "C" "tenant.id grouping contract failed"
fi

step "D. grouping cap, truncation and control-character rejection"
python3 - "${TMP_DIR}/prod/shard-00.native.json" "${TMP_DIR}" <<'PY'
import json, pathlib, sys
src, out = sys.argv[1], pathlib.Path(sys.argv[2])
events = json.load(open(src, encoding="utf-8"))
long_key = "x" * 300
for event in events:
    event["grouping"] = ([{"key": long_key, "value": "long-value"},
                          {"key": "bad", "value": "drop\u0007me"}] +
                         [{"key": f"k{i}", "value": f"v{i}"} for i in range(1, 11)])
json.dump(events, open(out / "bounds.native.json", "w", encoding="utf-8"), separators=(",", ":"))
(out / "long.toml").write_text(
    '[detection]\nn_plus_one_min_occurrences = 5\ngrouping_attributes = ["' +
    long_key + '", "bad"]\n', encoding="utf-8")
(out / "cap.toml").write_text(
    '[detection]\nn_plus_one_min_occurrences = 5\ngrouping_attributes = [' +
    ', '.join(f'"k{i}"' for i in range(1, 11)) + ']\n', encoding="utf-8")
PY
analyze "${TMP_DIR}/bounds.native.json" "${TMP_DIR}/long.toml" \
  "${TMP_DIR}/long.json" "${TMP_DIR}/long.err" || fail "D.truncate" "long-key analyze failed"
if python3 - "${TMP_DIR}/long.json" <<'PY'
import json, sys
findings = json.load(open(sys.argv[1], encoding="utf-8")).get("findings", [])
assert findings
assert all(len(f["grouping"]) == 1 for f in findings)
assert all(len(f["grouping"][0]["key"].encode()) == 256 for f in findings)
assert all("\u0007" not in json.dumps(f["grouping"]) for f in findings)
PY
then pass "D.truncate" "300-byte key truncates to 256 and the control pair disappears"
else fail "D.truncate" "truncation or control-character rejection failed"
fi
analyze "${TMP_DIR}/bounds.native.json" "${TMP_DIR}/cap.toml" \
  "${TMP_DIR}/cap.json" "${TMP_DIR}/cap.err" || fail "D.cap" "cap analyze failed"
if grep -q 'grouping_attributes exceeds the cap' "${TMP_DIR}/cap.err" \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["findings"] and all(len(f["grouping"]) == 8 for f in d["findings"])' "${TMP_DIR}/cap.json"; then
  pass "D.cap" "ten configured keys warn and retain the first eight"
else
  fail "D.cap" "cap warning or eight-attribute output missing"
fi

step "E. per-trace detectors partition one trace by grouping"
python3 - "${TMP_DIR}/detectors.native.json" <<'PY'
import json, sys

events = []
base = 1_780_000_000_000
seq = 0

def add(group, kind, target, duration_us, operation, offset_ms=0):
    global seq
    seq += 1
    events.append({
        "timestamp": "2026-05-27T00:00:%02d.%03dZ" % ((offset_ms // 1000) % 60, offset_ms % 1000),
        "trace_id": "mixed-grouping-trace", "span_id": "span-%04d" % seq,
        "parent_span_id": "root", "service": "mixed-service",
        "grouping": [{"key": "k8s.namespace.name", "value": group}],
        "cloud_region": "eu-west-3", "type": kind, "operation": operation,
        "target": target, "duration_us": duration_us,
        "source": {"endpoint": "/api/mixed", "method": "Mixed::handle"},
    })

for group in ("prod-eu", "staging-eu"):
    for i in range(6):
        add(group, "sql", f"SELECT * FROM orders WHERE id = {i}", 2_000, "SELECT", i * 2)
    for _ in range(2):
        add(group, "http_out", "https://inventory/items/42", 3_000, "GET", 30)
    for i in range(3):
        add(group, "sql", f"UPDATE slow_table SET flag = TRUE WHERE id = {i}", 250_000, "UPDATE", 40 + i)
    for i in range(5):
        add(group, "sql", f"SELECT value FROM pool_table_{i}", 200_000, "SELECT", 50)
    for i in range(6):
        add(group, "http_out", f"https://chatty-{i}.example.test/item", 2_000, "GET", 80 + i)

json.dump(events, open(sys.argv[1], "w", encoding="utf-8"), separators=(",", ":"))
PY
cat >"${TMP_DIR}/detectors.toml" <<'EOF'
[detection]
grouping_attributes = ["k8s.namespace.name"]
n_plus_one_min_occurrences = 5
slow_query_threshold_ms = 100
slow_min_occurrences = 3
pool_saturation_concurrent_threshold = 4
chatty_service_min_calls = 5
max_fanout = 100
EOF
analyze "${TMP_DIR}/detectors.native.json" "${TMP_DIR}/detectors.toml" \
  "${TMP_DIR}/detectors.json" "${TMP_DIR}/detectors.err" || fail "E" "detector analyze failed: $(tail -1 "${TMP_DIR}/detectors.err")"
if python3 - "${TMP_DIR}/detectors.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
by_type = {}
for finding in d.get("findings", []):
    grouping = finding.get("grouping") or []
    if grouping:
        by_type.setdefault(finding.get("type"), set()).add(grouping[0]["value"])
expected = {"n_plus_one_sql", "redundant_http", "slow_sql", "pool_saturation", "chatty_service"}
assert all(by_type.get(kind) == {"prod-eu", "staging-eu"} for kind in expected), by_type
PY
then pass "E" "N+1, redundant, slow, pool and chatty findings stay split inside one trace"
else fail "E" "one or more per-trace detectors merged or lost a grouping"
fi

step "F. diff keeps new groupings separate and falls back for a pre-0.11 baseline"
python3 - "${TMP_DIR}/two-groups.native.json" "${TMP_DIR}/legacy.native.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for event in d:
    event.pop("grouping", None)
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), separators=(",", ":"))
PY
"${PERF_SENTINEL_LOCAL_BIN}" diff --before "${TMP_DIR}/legacy.native.json" --after "${TMP_DIR}/two-groups.native.json" \
  --config "${TMP_DIR}/default.toml" \
  --format json --output "${TMP_DIR}/legacy-diff.json" >"${TMP_DIR}/legacy-diff.log" 2>&1 \
  || fail "F.legacy" "diff with legacy baseline failed"
if [ -s "${TMP_DIR}/legacy-diff.json" ] \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d["new_findings"] and not d["resolved_findings"]' "${TMP_DIR}/legacy-diff.json"; then
  pass "F.legacy" "pre-0.11 baseline does not become simultaneously new and resolved"
else fail "F.legacy" "legacy fallback produced false new/resolved findings"
fi
"${PERF_SENTINEL_LOCAL_BIN}" diff \
  --before "${TMP_DIR}/prod/shard-00.native.json" \
  --after "${TMP_DIR}/staging/shard-00.native.json" \
  --config "${TMP_DIR}/default.toml" \
  --format json --output "${TMP_DIR}/grouped-diff.json" >"${TMP_DIR}/grouped-diff.log" 2>&1 \
  || fail "F.grouped" "grouped diff failed"
if [ -s "${TMP_DIR}/grouped-diff.json" ] && python3 - "${TMP_DIR}/grouped-diff.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d.get("new_findings") and d.get("resolved_findings")
assert {f["grouping"][0]["value"] for f in d["new_findings"]} == {"staging-eu"}
assert {f["grouping"][0]["value"] for f in d["resolved_findings"]} == {"prod-eu"}
PY
then pass "F.grouped" "grouped diff reports staging new and prod resolved without folding"
else fail "F.grouped" "grouped diff folded the two deployments"
fi

step "G. real OTLP HTTP, gRPC and daemon JSON socket"
if ! command -v docker >/dev/null 2>&1; then
  fail "G.preflight" "docker is required for the real OTLP clients"
elif ! docker build -q -t "${TRACEGEN_IMAGE}" "${LAB_ROOT}/tools/tracegen" >/dev/null; then
  fail "G.preflight" "could not build ${TRACEGEN_IMAGE}"
else
  pass "G.preflight" "tracegen image built with the 0.11 grouping emitters"
fi

stop_daemon() {
  if [ -n "${DAEMON_PID}" ]; then
    kill "${DAEMON_PID}" 2>/dev/null || true
    wait "${DAEMON_PID}" 2>/dev/null || true
    DAEMON_PID=""
  fi
  rm -f "${SOCK}"
}

start_daemon() {  # grouping TOML array
  stop_daemon
  python3 - "${TMP_DIR}/daemon.toml" "${SOCK}" "${DAEMON_HTTP_PORT}" \
    "${DAEMON_GRPC_PORT}" "$1" <<'PY'
import sys
path, sock, http, grpc, grouping = sys.argv[1:]
open(path, "w", encoding="utf-8").write(f'''[daemon]
listen_address = "0.0.0.0"
listen_port_http = {http}
listen_port_grpc = {grpc}
json_socket = "{sock}"
api_enabled = true
trace_ttl_ms = 1000

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
grouping_attributes = [{grouping}]
''')
PY
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" \
    >"${TMP_DIR}/daemon.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do
    if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && [ -S "${SOCK}" ]; then
      return 0
    fi
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

send_otlp() {  # protocol, namespace, tenant, tps
  local protocol="$1" namespace="$2" tenant="$3" tps="$4" endpoint
  if [ "${protocol}" = "grpc" ]; then
    endpoint="host.docker.internal:${DAEMON_GRPC_PORT}"
  else
    endpoint="http://host.docker.internal:${DAEMON_HTTP_PORT}"
  fi
  docker run --rm --add-host host.docker.internal:host-gateway "${TRACEGEN_IMAGE}" \
    --protocol "${protocol}" --endpoint "${endpoint}" --duration 1 --tps "${tps}" \
    --batch-traces 1 --services 1 --service-prefix live --run-nonce contract \
    --mix n_plus_one:1 \
    --resource-attribute "k8s.namespace.name=${namespace}" \
    --resource-attribute service.namespace=commerce \
    --span-attribute "tenant.id=${tenant}" \
    >"${TMP_DIR}/send-${protocol}-${tenant}.json" \
    2>"${TMP_DIR}/send-${protocol}-${tenant}.err"
}

wait_for_groups() {  # output, key, expected values...
  local output="$1" key="$2"; shift 2
  local expected="$*"
  for _ in $(seq 1 30); do
    if curl -fsS "${DAEMON_URL}/api/export/report" >"${output}" 2>/dev/null \
      && python3 - "${output}" "${key}" "${expected}" 2>/dev/null <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
actual = sorted({f["grouping"][0]["value"] for f in d.get("findings", [])
                 if f.get("type") == "n_plus_one_sql" and f.get("grouping")
                 and f["grouping"][0]["key"] == sys.argv[2]})
assert actual == sorted(sys.argv[3].split()), actual
PY
    then return 0; fi
    sleep 0.5
  done
  return 1
}

if [ "${FAILURES}" -eq 0 ] || docker image inspect "${TRACEGEN_IMAGE}" >/dev/null 2>&1; then
  if ! start_daemon '"k8s.namespace.name", "service.namespace"'; then
    fail "G.daemon" "daemon failed to start: $(tail -2 "${TMP_DIR}/daemon.log")"
  elif ! send_otlp http-pb http-ns tenant-http 1; then
    fail "G.http" "OTLP HTTP sender failed: $(tail -2 "${TMP_DIR}/send-http-pb-tenant-http.err")"
  elif ! send_otlp grpc grpc-ns tenant-grpc 2; then
    fail "G.grpc" "OTLP gRPC sender failed: $(tail -2 "${TMP_DIR}/send-grpc-tenant-grpc.err")"
  elif wait_for_groups "${TMP_DIR}/otlp-report.json" k8s.namespace.name http-ns grpc-ns; then
    pass "G.otlp" "real OTLP HTTP and gRPC findings retain distinct resource groupings"
  else
    fail "G.otlp" "OTLP findings did not expose both http-ns and grpc-ns"
  fi

  if ! start_daemon '"tenant.id"'; then
    fail "G.tenant-daemon" "tenant daemon failed to start: $(tail -2 "${TMP_DIR}/daemon.log")"
  elif ! send_otlp http-pb shared-ns tenant-a 1 \
    || ! send_otlp grpc shared-ns tenant-b 2; then
    fail "G.tenant-otlp" "tenant OTLP sender failed"
  elif wait_for_groups "${TMP_DIR}/tenant-otlp-report.json" tenant.id tenant-a tenant-b; then
    pass "G.tenant-otlp" "span fallback splits tenants sharing one resource namespace"
  else
    fail "G.tenant-otlp" "tenant.id span fallback did not split the OTLP findings"
  fi

  if python3 "${TRACEGEN}" --protocol ndjson-socket --endpoint "${SOCK}" \
    --duration 1 --tps 1 --batch-traces 1 --services 1 \
    --service-prefix socket --run-nonce contract --mix n_plus_one:1 \
    --resource-attribute k8s.namespace.name=socket-ns \
    --span-attribute tenant.id=socket-tenant \
    >"${TMP_DIR}/socket-send.json" 2>"${TMP_DIR}/socket-send.err" \
    && wait_for_groups "${TMP_DIR}/socket-report.json" tenant.id tenant-a tenant-b socket-tenant; then
    pass "G.socket" "daemon JSON socket applies the configured tenant grouping"
  else
    fail "G.socket" "JSON socket grouping failed: $(tail -2 "${TMP_DIR}/socket-send.err")"
  fi

  if curl -fsS "${DAEMON_URL}/api/findings" >"${TMP_DIR}/api-findings.json" \
    && python3 - "${TMP_DIR}/api-findings.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1], encoding="utf-8"))
assert items and isinstance(items, list)
findings = [item.get("finding", item) for item in items]
assert all("service_namespace" not in f and "k8s_namespace" not in f for f in findings)
assert all(isinstance(f.get("grouping"), list) for f in findings)
PY
  then pass "G.api" "/api/findings exposes grouping and no retired namespace fields"
  else fail "G.api" "/api/findings violated the 0.11 contract"
  fi
fi

step "H. rendered HTML and browser-generated CSV contracts"
BROWSER_CHECK="${LAB_ROOT}/scenarios/ci-e2e-common/browser-check.sh"
python3 - "${TMP_DIR}/default.json" "${TMP_DIR}/dashboard.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["correlations"] = [{
    "source": {
        "finding_type": "n_plus_one_sql", "service": "grouping-contract-0000",
        "template": "SELECT * FROM orders WHERE id = ?",
        "grouping_key": "k8s.namespace.name", "grouping_value": "prod-eu",
    },
    "target": {
        "finding_type": "slow_sql", "service": "payment-service",
        "template": "SELECT * FROM payments WHERE order_id = ?",
        "grouping_key": "k8s.namespace.name", "grouping_value": "prod-eu",
    },
    "co_occurrence_count": 3, "source_total_occurrences": 3,
    "confidence": 1.0, "median_lag_ms": 12.0,
    "first_seen": "2026-08-07T08:00:00Z", "last_seen": "2026-08-07T08:01:00Z",
}]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), separators=(",", ":"))
PY
if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${TMP_DIR}/dashboard.json" \
  --output "${TMP_DIR}/dashboard.html" >"${TMP_DIR}/report.log" 2>&1; then
  pass "H.report" "pre-computed 0.11 report renders to HTML"
else
  fail "H.report" "HTML report failed: $(tail -2 "${TMP_DIR}/report.log")"
fi

if "${BROWSER_CHECK}" "${TMP_DIR}/dashboard.html" dom >"${TMP_DIR}/dom.txt" \
  && grep -q 'k8s.namespace.name=prod-eu' "${TMP_DIR}/dom.txt" \
  && grep -q 'k8s.namespace.name=staging-eu' "${TMP_DIR}/dom.txt"; then
  pass "H.dom" "real Chrome renders both deployment identities"
else
  fail "H.dom" "rendered dashboard did not expose both grouping labels"
fi

if "${BROWSER_CHECK}" "${TMP_DIR}/dashboard.html" findings >"${TMP_DIR}/findings.csv" \
  && python3 - "${TMP_DIR}/findings.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8", newline="")))
assert rows
assert {"grouping_key", "grouping_value", "grouping_all"}.issubset(rows[0])
assert {row["grouping_value"] for row in rows} == {"prod-eu", "staging-eu"}
assert all(row["grouping_key"] == "k8s.namespace.name" for row in rows)
assert all("service.namespace=commerce" in row["grouping_all"] for row in rows)
PY
then pass "H.findings-csv" "browser CSV uses grouping_key/value/all with both deployments"
else fail "H.findings-csv" "findings CSV grouping columns or values are wrong"
fi

if "${BROWSER_CHECK}" "${TMP_DIR}/dashboard.html" correlations >"${TMP_DIR}/correlations.csv" \
  && python3 - "${TMP_DIR}/correlations.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8", newline="")))
assert len(rows) == 1
row = rows[0]
assert row["grouping_key_a"] == row["grouping_key_b"] == "k8s.namespace.name"
assert row["grouping_value_a"] == row["grouping_value_b"] == "prod-eu", row
PY
then pass "H.correlations-csv" "correlation CSV reads grouping_value on both endpoints"
else fail "H.correlations-csv" "correlation CSV lost grouping_value (0.11 release blocker)"
fi

step "Summary"
VERDICT="PASS"; [ "${FAILURES}" -gt 0 ] && VERDICT="FAIL"
{
  echo "# perf-sentinel 0.11 grouping identity"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Binary: ${VERSION} (${PRODUCT_COMMIT})"
  echo
  echo "| check | verdict | evidence |"
  echo "|---|---|---|"
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r name verdict note <<<"${row}"
    printf '| %s | %s | %s |\n' "${name}" "${verdict}" "${note}"
  done
  echo
  echo "**Verdict: ${VERDICT}**"
} >"${REPORT}"

if [ "${VERDICT}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
fi
die "${FAILURES} grouping assertion(s) failed, see ${REPORT}"
