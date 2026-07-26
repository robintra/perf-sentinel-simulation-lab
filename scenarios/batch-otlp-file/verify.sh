#!/usr/bin/env bash
# batch-otlp-file: validate perf-sentinel 0.9.5's OTLP/JSON batch ingestion —
# the Collector `file` exporter NDJSON dump fed straight to `analyze`/`report`,
# no Tempo/Jaeger backend. The headline path is dd-trace -> datadogreceiver ->
# file exporter -> analyze (docker collector, tee'd to a loopback daemon for
# coherence); the native-OTel leg runs through the CLUSTER collector via a
# values overlay (SKIP cleanly when no cluster is reachable).
#
# Assertions (see README.md):
#   A1  analyze on the dd-trace NDJSON dump: exit 0, traces_analyzed > 0,
#       an N+1/redundant SQL finding (strict sanitizer config, dd-trace SQL
#       is pre-obfuscated).
#   A2  batch findings coherent with what the daemon detects on the SAME
#       tee'd traffic (/api/findings).
#   A3  same assertions on native OTel traffic through the cluster collector
#       (order-service faults -> overlay file exporter -> node dump).
#   A4  truncated trailing line (rotation/in-flight write): exit 0 + the
#       "truncated trailing OTLP JSON document" warning, complete lines kept.
#   A5  negatives: a half-line-only file and mid-stream garbage both exit 1.
#   A6  detection non-regression: a Jaeger UI export stays Jaeger even with a
#       "resourceSpans" tag value; an OTLP dump with an attribute named/valued
#       "data" stays OTLP (single pretty-printed object form).
#   A7  report --input <dump> renders a usable dashboard.
set -uo pipefail

SCENARIO="batch-otlp-file"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JAEGER_FIXTURE="${SCRIPT_DIR}/../datadog-bridge/fixtures/crossfmt-jaeger.json"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/dump"
chmod 777 "${TMP_DIR}/dump"   # the contrib collector runs as UID 10001

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${DAEMON_HTTP_PORT:-14396}"
DAEMON_GRPC_PORT="${DAEMON_GRPC_PORT:-14397}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
DD_PORT="${DD_PORT:-8127}"
# Same contrib pin as datadog-bridge (the datadogreceiver is alpha).
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.155.0}"
# Version of the ALREADY-INSTALLED collector release. A `helm upgrade` naming a
# different version silently up- or downgrades the cluster collector for every
# later scenario, and the three hardcoded pins had drifted apart (0.153.0 in
# multiformat-input, 0.160.0 in batch-otlp-file, 0.165.0 in scripts/bootstrap.sh).
# Resolved lazily so a run with no cluster still reaches its SKIP path.
otel_chart_version() {
  local v
  v="$(helm -n observability get metadata otel-collector 2>/dev/null | awk '/^VERSION:/{print $2}')"
  [ -n "${v}" ] || { echo "cannot read the installed otel-collector chart version" >&2; return 1; }
  printf '%s' "${v}"
}
DUMP="${TMP_DIR}/dump/otlp-dump.ndjson"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

DAEMON_PID=""
PF_PIDS=""
CLUSTER_OVERLAY_APPLIED=0
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  for pid in ${PF_PIDS}; do kill "${pid}" 2>/dev/null || true; done
  docker rm -f "bofile-collector" >/dev/null 2>&1 || true
  if [ "${CLUSTER_OVERLAY_APPLIED}" = "1" ]; then
    # Revert the cluster collector to the base values (drops file/dump + the
    # hostPath mount). Same idempotent pattern as multiformat-input.
    helm upgrade otel-collector open-telemetry/opentelemetry-collector \
      --version "$(otel_chart_version)" -n observability \
      -f "${REPO_ROOT}/helm/values/otel-collector.yaml" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — the dd-trace leg needs a throwaway collector container"
python3 -c "import msgpack" 2>/dev/null || die "python3-msgpack missing (needed by dd_send.py)"
[ -f "${JAEGER_FIXTURE}" ] || die "missing Jaeger fixture ${JAEGER_FIXTURE}"

# dd-trace SQL is pre-obfuscated -> strict sanitizer mode, mirrored between
# the batch config and the loopback daemon so A2 compares like with like.
cat > "${TMP_DIR}/strict.toml" <<EOF
[detection]
n_plus_one_min_occurrences = 5
sanitizer_aware_classification = "strict"
EOF

free_daemon_port() {
  pkill -f "perf-sentinel watch.*${TMP_DIR}/daemon.toml" 2>/dev/null || true
  for p in "${DAEMON_HTTP_PORT}" "${DAEMON_GRPC_PORT}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}

finding_types_for() {  # $1 = service ; findings JSON (bare or wrapped) on stdin
  python3 -c '
import sys, json
svc = sys.argv[1]
d = json.load(sys.stdin)
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
print(" ".join(sorted(set(u(it).get("type","") for it in items if u(it).get("service") == svc))))
' "$1"
}

run_analyze() {  # $1 = input file ; stdout->out.json stderr->err.txt ; rc passthrough
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$1" --config "${TMP_DIR}/strict.toml" \
    --format json > "${TMP_DIR}/out.json" 2> "${TMP_DIR}/err.txt"
}

traces_analyzed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"])' "${TMP_DIR}/out.json"; }

# ── dd-trace leg: datadogreceiver + file exporter tee ───────────────────────
step "Loopback daemon (strict) + collector with datadogreceiver -> {daemon, file} tee"
free_daemon_port
sleep 1
cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "0.0.0.0"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
api_enabled = true
trace_ttl_ms = 2000
environment = "staging"

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
sanitizer_aware_classification = "strict"
EOF
"${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && break; sleep 0.5
done
curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 || die "daemon not ready: $(tail -3 "${TMP_DIR}/daemon.log")"

sed "s#host.docker.internal:14396#host.docker.internal:${DAEMON_HTTP_PORT}#" \
  "${SCRIPT_DIR}/collector-ddtrace.yaml" > "${TMP_DIR}/collector.yaml"
docker rm -f bofile-collector >/dev/null 2>&1 || true
docker run -d --name bofile-collector --add-host=host.docker.internal:host-gateway \
  -p "${DD_PORT}:8126" \
  -v "${TMP_DIR}/collector.yaml:/cfg/config.yaml:ro" \
  -v "${TMP_DIR}/dump:/var/otel" \
  "${COLLECTOR_IMAGE}" --config=/cfg/config.yaml >/dev/null || die "collector start failed"
ready=0
for _ in $(seq 1 30); do
  docker logs bofile-collector 2>&1 | grep -qi "Everything is ready" && { ready=1; break; }
  docker ps --format '{{.Names}}' | grep -q bofile-collector \
    || die "collector crashed: $(docker logs bofile-collector 2>&1 | tail -3)"
  sleep 1
done
[ "${ready}" = "1" ] || die "datadogreceiver not ready (no startup banner)"
sleep 1

step "Send 3 dd-trace N+1 traces, wait for 3 NDJSON lines in the dump"
DD_PORT="${DD_PORT}" python3 "${SCRIPT_DIR}/dd_send.py" 3 > "${TMP_DIR}/send.log" 2>&1 \
  || die "dd_send failed: $(tail -2 "${TMP_DIR}/send.log")"
LINES=0
for _ in $(seq 1 30); do
  LINES=$(wc -l < "${DUMP}" 2>/dev/null | tr -d ' ' || echo 0)
  [ "${LINES}" -ge 3 ] && break
  sleep 1
done
[ "${LINES:-0}" -ge 3 ] || die "file exporter wrote ${LINES:-0}/3 NDJSON lines"
ok "dump has ${LINES} NDJSON lines (one ExportTraceServiceRequest per intake)"
cp "${DUMP}" "${TMP_DIR}/dd-dump.ndjson"

# ── A1: analyze on the raw NDJSON dump ──────────────────────────────────────
step "A1: analyze --input <NDJSON dump> (strict)"
if run_analyze "${TMP_DIR}/dd-dump.ndjson"; then
  TA="$(traces_analyzed)"
  DD_TYPES="$(finding_types_for dd-shop < "${TMP_DIR}/out.json")"
  if [ "${TA}" -gt 0 ] && echo "${DD_TYPES}" | grep -Eq 'n_plus_one_sql|redundant_sql'; then
    assert_pass "A1" "exit 0, traces_analyzed=${TA}, dd-shop SQL finding [${DD_TYPES}]"
    cp "${TMP_DIR}/out.json" "${TMP_DIR}/batch-findings.json"
  else
    assert_fail "A1" "traces_analyzed=${TA}, dd-shop types=[${DD_TYPES}] (want an N+1/redundant SQL finding)"
  fi
else
  assert_fail "A1" "analyze exited non-zero on the NDJSON dump: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# ── A2: coherence with the daemon on the same tee'd traffic ─────────────────
step "A2: batch findings vs daemon /api/findings on the SAME traffic"
sleep 4    # let the daemon's rolling window close on the tee'd traces
if curl -fsS "${DAEMON_URL}/api/findings" > "${TMP_DIR}/daemon-findings.json" 2>/dev/null; then
  DAEMON_TYPES="$(finding_types_for dd-shop < "${TMP_DIR}/daemon-findings.json")"
  BATCH_TYPES="$(finding_types_for dd-shop < "${TMP_DIR}/batch-findings.json" 2>/dev/null || echo "")"
  COMMON="$(python3 -c "
b = set('${BATCH_TYPES}'.split()) - {''}
d = set('${DAEMON_TYPES}'.split()) - {''}
print(len(b & d))")"
  if [ "${COMMON}" -ge 1 ]; then
    assert_pass "A2" "coherent: batch=[${BATCH_TYPES}] daemon=[${DAEMON_TYPES}], ${COMMON} common type(s)"
  else
    assert_fail "A2" "no common finding type: batch=[${BATCH_TYPES}] daemon=[${DAEMON_TYPES}]"
  fi
else
  assert_fail "A2" "daemon /api/findings unreachable"
fi

# ── A3: native OTel traffic through the CLUSTER collector ───────────────────
step "A3: native OTel -> cluster collector file exporter (overlay)"
if kubectl -n observability get ds >/dev/null 2>&1; then
  # fsGroup does not apply to hostPath volumes: pre-create the dump dir
  # world-writable on every k3d node so the UID-10001 collector can write.
  for node in $(docker ps --format '{{.Names}}' | grep -E '^k3d-.*-(server|agent)-[0-9]+$'); do
    docker exec "${node}" sh -c 'rm -rf /tmp/otel-dump && mkdir -p -m 777 /tmp/otel-dump' \
      || die "cannot prepare /tmp/otel-dump on ${node}"
  done
  # Arm the revert BEFORE the upgrade: a partial apply that then errors has
  # still mutated the shared cluster collector, and the EXIT trap must revert it
  # (a non-atomic helm upgrade has no rollback of its own).
  CLUSTER_OVERLAY_APPLIED=1
  helm upgrade otel-collector open-telemetry/opentelemetry-collector \
    --version "$(otel_chart_version)" -n observability \
    -f "${REPO_ROOT}/helm/values/otel-collector.yaml" \
    -f "${SCRIPT_DIR}/collector-overlay.yaml" > "${TMP_DIR}/helm.log" 2>&1 \
    || die "helm upgrade with file-exporter overlay failed: $(tail -3 "${TMP_DIR}/helm.log")"
  DS_NAME="$(kubectl -n observability get ds -o name | grep -m1 otel-collector)"
  kubectl -n observability rollout status "${DS_NAME}" --timeout=180s >/dev/null \
    || die "collector daemonset rollout did not converge"

  # Targeted burst (multiformat-input pattern): N+1 faults on order-service.
  ORDER_POD=$(kubectl -n shop get pod -l app.kubernetes.io/name=order-service -o jsonpath='{.items[0].metadata.name}')
  kubectl -n shop port-forward "${ORDER_POD}" 18281:8080 > "${TMP_DIR}/pf-order.log" 2>&1 &
  PF_PIDS="${PF_PIDS} $!"
  sleep 5
  for _ in $(seq 1 10); do
    curl -fsS -X POST "http://localhost:18281/api/fault/n-plus-one-sql?items=15" >/dev/null 2>&1 || true
    sleep 0.3
  done
  sleep 10   # batch processor timeout is 5s; give the file exporter slack

  # The contrib image is scratch-based (no tar -> no kubectl cp): read the
  # hostPath dump straight off every k3d node container and concatenate.
  : > "${TMP_DIR}/cluster-dump.ndjson"
  for node in $(docker ps --format '{{.Names}}' | grep -E '^k3d-.*-(server|agent)-[0-9]+$'); do
    docker exec "${node}" cat /tmp/otel-dump/otlp-dump.ndjson 2>/dev/null \
      >> "${TMP_DIR}/cluster-dump.ndjson" || true
  done
  if [ -s "${TMP_DIR}/cluster-dump.ndjson" ] && run_analyze "${TMP_DIR}/cluster-dump.ndjson"; then
    TA="$(traces_analyzed)"
    OS_TYPES="$(finding_types_for order-service < "${TMP_DIR}/out.json")"
    if [ "${TA}" -gt 0 ] && echo "${OS_TYPES}" | grep -q 'n_plus_one_sql'; then
      assert_pass "A3" "native OTel dump: traces_analyzed=${TA}, order-service [${OS_TYPES}]"
    else
      assert_fail "A3" "native OTel dump: traces_analyzed=${TA}, order-service types=[${OS_TYPES}]"
    fi
  else
    assert_fail "A3" "empty cluster dump or analyze failed: $(tail -2 "${TMP_DIR}/err.txt" 2>/dev/null)"
  fi
else
  skip "no reachable cluster — native-OTel leg skipped (dd-trace leg covers the ingest path)"
  record "A3" "SKIP — cluster unreachable"
fi

# ── A4: truncated trailing line is tolerated with a warning ─────────────────
step "A4: truncated trailing line -> exit 0 + warning + complete lines analyzed"
TOTAL=$(wc -c < "${TMP_DIR}/dd-dump.ndjson")
LAST=$(tail -1 "${TMP_DIR}/dd-dump.ndjson" | wc -c)
head -c "$((TOTAL - LAST / 2))" "${TMP_DIR}/dd-dump.ndjson" > "${TMP_DIR}/truncated.ndjson"
if run_analyze "${TMP_DIR}/truncated.ndjson"; then
  TA="$(traces_analyzed)"
  if grep -q "truncated trailing OTLP JSON document" "${TMP_DIR}/err.txt" && [ "${TA}" -gt 0 ]; then
    assert_pass "A4" "exit 0, warning emitted, ${TA} complete trace(s) analyzed"
  else
    assert_fail "A4" "exit 0 but warning missing or nothing analyzed (traces=${TA}): $(tail -2 "${TMP_DIR}/err.txt")"
  fi
else
  assert_fail "A4" "truncated tail should be tolerated but analyze exited non-zero: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# ── A5: negatives — nothing complete, or garbage mid-stream ─────────────────
step "A5: half-line-only file and mid-stream garbage both exit 1"
head -c 200 "${TMP_DIR}/dd-dump.ndjson" > "${TMP_DIR}/half-line.ndjson"
NEG1_RC=0; run_analyze "${TMP_DIR}/half-line.ndjson" || NEG1_RC=$?
{ head -1 "${TMP_DIR}/dd-dump.ndjson"; echo "this is not OTLP JSON"; sed -n '2p' "${TMP_DIR}/dd-dump.ndjson"; } \
  > "${TMP_DIR}/garbage-mid.ndjson"
NEG2_RC=0; run_analyze "${TMP_DIR}/garbage-mid.ndjson" || NEG2_RC=$?
if [ "${NEG1_RC}" != "0" ] && [ "${NEG2_RC}" != "0" ]; then
  assert_pass "A5" "half-line rc=${NEG1_RC}, mid-stream garbage rc=${NEG2_RC} (both hard errors)"
else
  assert_fail "A5" "expected exit 1 on both: half-line rc=${NEG1_RC}, garbage rc=${NEG2_RC}"
fi

# ── A6: detection non-regression (Jaeger vs OTLP sniffing) ──────────────────
step "A6: Jaeger export with a 'resourceSpans' tag stays Jaeger; OTLP with a 'data' attribute stays OTLP"
python3 - "${JAEGER_FIXTURE}" "${TMP_DIR}/jaeger-trap.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"][0]["spans"][0]["tags"].append(
    {"key": "note", "type": "string", "value": "resourceSpans"})
json.dump(d, open(sys.argv[2], "w"))
PY
# Baseline trace counts from the PRISTINE files parsed by their correct parser.
# Asserting the trap yields the SAME count (not merely >0) catches a lenient
# misroute: if the trap were parsed by the wrong parser it would fail outright
# OR analyze to a different count — a bare traces>0 check would miss the latter.
run_analyze "${JAEGER_FIXTURE}" || die "A6: pristine Jaeger fixture failed to analyze"
JAEGER_BASE="$(traces_analyzed)"
head -1 "${TMP_DIR}/dd-dump.ndjson" > "${TMP_DIR}/otlp-base.json"
run_analyze "${TMP_DIR}/otlp-base.json" || die "A6: pristine single OTLP request failed to analyze"
OTLP_BASE="$(traces_analyzed)"
JAEGER_RC=0; run_analyze "${TMP_DIR}/jaeger-trap.json" || JAEGER_RC=$?
JAEGER_TA=0; [ "${JAEGER_RC}" = "0" ] && JAEGER_TA="$(traces_analyzed)"
python3 - "${TMP_DIR}/dd-dump.ndjson" "${TMP_DIR}/otlp-trap.json" <<'PY'
import json, sys
# Single pretty-printed request (exercises the non-NDJSON form too) with an
# attribute both NAMED and VALUED "data" on the first span.
d = json.loads(open(sys.argv[1]).readline())
span = d["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
span.setdefault("attributes", []).append(
    {"key": "data", "value": {"stringValue": "data"}})
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OTLP_RC=0; run_analyze "${TMP_DIR}/otlp-trap.json" || OTLP_RC=$?
OTLP_TA=0; [ "${OTLP_RC}" = "0" ] && OTLP_TA="$(traces_analyzed)"
# Each trap must exit 0 AND analyze to the same count as its pristine baseline
# (>0) — proving it was routed to the correct parser, not leniently mis-parsed.
if [ "${JAEGER_RC}" = "0" ] && [ "${JAEGER_TA}" -gt 0 ] && [ "${JAEGER_TA}" = "${JAEGER_BASE}" ] \
   && [ "${OTLP_RC}" = "0" ] && [ "${OTLP_TA}" -gt 0 ] && [ "${OTLP_TA}" = "${OTLP_BASE}" ]; then
  assert_pass "A6" "jaeger-trap analyzed as Jaeger (traces=${JAEGER_TA}=${JAEGER_BASE}), otlp-trap as OTLP (traces=${OTLP_TA}=${OTLP_BASE})"
else
  assert_fail "A6" "jaeger rc=${JAEGER_RC}/traces=${JAEGER_TA}(base ${JAEGER_BASE}), otlp rc=${OTLP_RC}/traces=${OTLP_TA}(base ${OTLP_BASE})"
fi

# ── A7: report on the dump ──────────────────────────────────────────────────
step "A7: report --input <dump> renders a usable dashboard"
if "${PERF_SENTINEL_LOCAL_BIN}" report --input "${TMP_DIR}/dd-dump.ndjson" \
     --output "${TMP_DIR}/r.html" > /dev/null 2> "${TMP_DIR}/err.txt" \
   && [ -s "${TMP_DIR}/r.html" ] && grep -q "dd-shop" "${TMP_DIR}/r.html"; then
  assert_pass "A7" "dashboard rendered from the NDJSON dump ($(wc -c < "${TMP_DIR}/r.html" | tr -d ' ') bytes, dd-shop present)"
else
  assert_fail "A7" "report failed or dashboard empty: $(tail -2 "${TMP_DIR}/err.txt")"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel 0.9.5 OTLP/JSON batch input from the Collector file exporter."
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
