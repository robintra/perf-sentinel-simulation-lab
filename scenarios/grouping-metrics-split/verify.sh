#!/usr/bin/env bash
# grouping-metrics-split: the 0.19.0 `grouping` label on the five metric
# families, and the per-(service, grouping) pair caps behind it.
#
# 0.19.0 puts a `grouping` label next to `service` on
# `perf_sentinel_findings_total`, `perf_sentinel_slow_duration_seconds` and
# the three `perf_sentinel_service_*_io_ops_total` counters. Its value is the
# finding's effective grouping, so on Kubernetes the namespace the analysed
# traffic runs in. That splits one series into one per namespace, which is the
# point, and it is also the risk: a split that does not preserve the totals
# silently rewrites every waste figure an operator reads.
#
# Four claims, none of which any other scenario covers. `grouping-identity`
# pins the grouping VALUE across ingestion boundaries and the JSON/CSV
# contracts; it never looks at /metrics. `limit-service-cardinality` pins the
# service caps; the pair caps are a second, independent gate.
#
#   A. Split. One service name in two groupings is two series, not one, on
#      every family that gained the label.
#   B. Sum invariant. `sum by (service)` over the new label returns exactly the
#      0.18.0 per-service series and `sum()` the pre-0.18 total. Proven as an
#      A/B on identical traffic: the same runs replayed into a daemon with
#      `per_grouping_labels = false`, which IS the 0.18.0 shape.
#   C. Fold. Past the pair caps (512 analysis, 256 histogram, 4096 ingest) a
#      pair keeps its service and folds only its grouping into `_other`, the
#      three overflow counters move, and B still holds. The loop stays at 40
#      services so the SERVICE caps (128 analysis, 64 histogram, 1024 ingest)
#      never fire: what folds here is the grouping axis alone, and the service
#      overflow counters staying at 0 is what proves it.
#   D. Knob. `[daemon] per_grouping_labels = false` empties the label on all
#      five families, which PromQL treats as absent, and unlike
#      `per_service_labels` it governs the three I/O counters too. Plus the
#      startup rule that changed with it: the histogram's unlabelled series is
#      pre-warmed only when BOTH knobs are off.
#
# Self-contained: local release binary, python3, curl. No cluster, no Docker.
# SKIPs (exit 0) without a local binary, and again if the daemon it starts has
# no `per_grouping_labels` on /api/config, so a pre-0.19 pin does not fail it.
set -uo pipefail

SCENARIO="grouping-metrics-split"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
TRACEGEN="${LAB_ROOT}/tools/tracegen/tracegen.py"
PARSE="${SCENARIO_DIR}/parse_metrics.py"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_HTTP_PORT="${GMS_DAEMON_HTTP_PORT:-14818}"
DAEMON_GRPC_PORT="${GMS_DAEMON_GRPC_PORT:-14817}"
DAEMON_URL="http://127.0.0.1:${DAEMON_HTTP_PORT}"
# AF_UNIX paths cap out around 104 bytes, so /tmp rather than TMP_DIR.
SOCK="/tmp/ps-gms-$$.sock"

# Leg C sizing. 40 services x 110 namespaces is 4400 admitted pairs, past all
# three caps, while 40 services stays under the lowest service cap (64, the
# histogram's). Lower it to shorten a local run; the leg asserts the caps were
# actually crossed rather than trusting the arithmetic.
SAT_ITERATIONS="${SAT_ITERATIONS:-110}"
SAT_SERVICES="${SAT_SERVICES:-40}"

# Documented caps, asserted rather than recomputed: a silent change upstream
# has to show up here.
CAP_ANALYSIS_PAIRS=512
CAP_HISTOGRAM_PAIRS=256
CAP_INGEST_PAIRS=4096

FAMILIES_COUNTER="perf_sentinel_findings_total \
perf_sentinel_service_avoidable_io_ops_total \
perf_sentinel_service_analyzed_io_ops_total \
perf_sentinel_service_io_ops_total"
FAMILY_HISTOGRAM="perf_sentinel_slow_duration_seconds"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
# A stale PASS report must not outlive a failing re-run.
rm -f "${REPORT}"

color_blue()   { printf '\033[34m%s\033[0m\n' "$*"; }
color_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
color_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red "    error: $*"; exit 1; }

FAILURES=0
declare -a RESULTS=()
pass() { ok "$2"; RESULTS+=("$1|PASS|$2"); }
fail() { color_red "    FAIL: $2"; RESULTS+=("$1|FAIL|$2"); FAILURES=$((FAILURES + 1)); }

DAEMON_PID=""
cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  rm -f "${SOCK}" 2>/dev/null || true
}
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------

start_daemon() {  # $1 per_service_labels, $2 per_grouping_labels, $3 tag
  if [ -n "${DAEMON_PID}" ]; then
    kill "${DAEMON_PID}" 2>/dev/null || true
    wait "${DAEMON_PID}" 2>/dev/null || true
    DAEMON_PID=""
  fi
  # Require the port to fall silent: a leftover daemon from an aborted run
  # would answer readiness and every leg below would grade the wrong process.
  for _ in $(seq 1 20); do
    curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 || break
    sleep 0.5
  done
  curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
    && die "something already serves ${DAEMON_URL}, leftover daemon from a previous run?"
  rm -f "${SOCK}"
  cat > "${TMP_DIR}/daemon-$3.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${DAEMON_HTTP_PORT}
listen_port_grpc = ${DAEMON_GRPC_PORT}
json_socket = "${SOCK}"
api_enabled = true
trace_ttl_ms = 1000
per_service_labels = $1
per_grouping_labels = $2

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
slow_query_threshold_ms = 100
slow_query_min_occurrences = 3
EOF
  "${PERF_SENTINEL_LOCAL_BIN}" watch --config "${TMP_DIR}/daemon-$3.toml" \
    > "${TMP_DIR}/daemon-$3.log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 80); do
    if curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 && [ -S "${SOCK}" ]; then
      return 0
    fi
    kill -0 "${DAEMON_PID}" 2>/dev/null || return 1
    sleep 0.25
  done
  return 1
}

send() {  # $1 namespace, $2 services, $3 tps, $4 duration, $5 nonce
  # traces >= services, so the round-robin service assignment covers them all:
  # a short run would otherwise admit fewer pairs than the leg counts on.
  python3 "${TRACEGEN}" --protocol ndjson-socket --endpoint "${SOCK}" \
    --duration "$4" --tps "$3" --batch-traces 10 --services "$2" \
    --service-prefix gms --run-nonce "$5" \
    --mix n_plus_one:40,slow:30,redundant:15,clean:15 \
    --resource-attribute "k8s.namespace.name=$1" \
    > "${TMP_DIR}/send-$5-$1.json" 2>> "${TMP_DIR}/send.err"
}

scrape() { curl -fsS "${DAEMON_URL}/metrics" > "$1"; }

parse() { python3 "${PARSE}" "$@"; }

counter_value() {  # $1 metrics file, $2 metric name -> the sample, or 0
  local v
  v="$(parse value "$1" "$2")"
  [ -n "${v}" ] && printf '%s\n' "${v}" || printf '0\n'
}

# The two short runs leg A and leg B grade, replayed identically into whichever
# daemon is currently up. tracegen is seeded, so the payloads match byte for
# byte across replays.
phase_split() {  # $1 = output metrics file
  send alpha 3 8 3 split
  send beta 3 8 3 split
  sleep 6
  scrape "$1"
}

step "0. Pre-flight"
if [ ! -x "${PERF_SENTINEL_LOCAL_BIN}" ]; then
  skip "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release --workspace first); scenario skipped"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"
command -v curl >/dev/null 2>&1    || die "curl not on PATH"
[ -f "${TRACEGEN}" ] || die "no tracegen at ${TRACEGEN}"
VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
PRODUCT_COMMIT="$(git -C "${PERF_SENTINEL_REPO_PATH}" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
ok "perf-sentinel ${VERSION} (${PRODUCT_COMMIT})"

start_daemon true true probe || die "daemon failed to start: $(tail -3 "${TMP_DIR}/daemon-probe.log")"
# Feature probe, not a version gate: the branch that adds the label keeps the
# previous version in Cargo.toml until tag time, so `--version` cannot answer
# this. An older pin has no such key and the scenario skips instead of failing.
if ! curl -fsS "${DAEMON_URL}/api/config" > "${TMP_DIR}/config.json" \
  || ! python3 -c 'import json,sys; sys.exit(0 if "per_grouping_labels" in json.load(open(sys.argv[1])) else 1)' \
       "${TMP_DIR}/config.json"; then
  skip "/api/config has no per_grouping_labels: daemon ${VERSION} predates the 0.19.0 grouping label, scenario skipped"
  exit 0
fi
pass "0.config" "/api/config reports per_grouping_labels (0.19.0 grouping label present)"

step "A. one service in two groupings is two series"
phase_split "${TMP_DIR}/metrics-on.txt"
A_FAILED=0
for family in ${FAMILIES_COUNTER} ${FAMILY_HISTOGRAM}; do
  groupings="$(parse groupings "${TMP_DIR}/metrics-on.txt" "${family}" | tr '\n' ' ')"
  services="$(parse services "${TMP_DIR}/metrics-on.txt" "${family}" | grep -c .)"
  labels="$(parse arity "${TMP_DIR}/metrics-on.txt" "${family}" | tr '\n' ',' | sed 's/,$//')"
  case "${family}" in
    perf_sentinel_findings_total)         want="grouping,service,severity,type" ;;
    perf_sentinel_slow_duration_seconds)  want="grouping,service,type" ;;
    *)                                    want="grouping,service" ;;
  esac
  # The claim is not "two grouping values exist" but "one service name is now
  # two series", so the pair count must be twice the service count. Required of
  # the four counter families only: the histogram carries a series only for a
  # service that had a slow span, so a service present in one namespace and not
  # the other is legitimate there and would make this check flaky.
  pairs="$(parse pairs "${TMP_DIR}/metrics-on.txt" "${family}" | grep -c .)"
  expected_pairs=$((2 * services))
  [ "${family}" = "${FAMILY_HISTOGRAM}" ] && expected_pairs="${pairs}"
  if [ "${labels}" != "${want}" ]; then
    fail "A.arity" "${family} carries labels [${labels}], expected [${want}]"
    A_FAILED=1
  elif [ "${groupings}" != "alpha beta " ]; then
    fail "A.split" "${family} groupings are [${groupings}], expected alpha and beta"
    A_FAILED=1
  elif [ "${services}" -lt 1 ]; then
    fail "A.split" "${family} exposes no service"
    A_FAILED=1
  elif [ "${pairs}" -ne "${expected_pairs}" ]; then
    fail "A.split" "${family} has ${pairs} (service, grouping) pairs for ${services} services, expected ${expected_pairs}: the same service is not present under both groupings"
    A_FAILED=1
  fi
done
[ "${A_FAILED}" -eq 0 ] \
  && pass "A" "all five families carry grouping next to service and split alpha from beta"

step "B. sum by (service) returns the 0.18.0 shape, sum() the pre-0.18 one"
start_daemon true false off || die "knob-off daemon failed to start"
phase_split "${TMP_DIR}/metrics-off.txt"
B_FAILED=0
for family in ${FAMILIES_COUNTER} ${FAMILY_HISTOGRAM}; do
  # `sum by (service)` of the labelled daemon against the plain per-service
  # series of the unlabelled one: the same PromQL identity, evaluated on two
  # daemons fed the same bytes.
  if ! diff -q <(parse sumsvc "${TMP_DIR}/metrics-on.txt" "${family}") \
               <(parse sumsvc "${TMP_DIR}/metrics-off.txt" "${family}") >/dev/null; then
    fail "B.sumsvc" "${family}: sum by (service) differs between the split and the 0.18.0 shape"
    diff <(parse sumsvc "${TMP_DIR}/metrics-on.txt" "${family}") \
         <(parse sumsvc "${TMP_DIR}/metrics-off.txt" "${family}") | head -6
    B_FAILED=1
  elif [ "$(parse total "${TMP_DIR}/metrics-on.txt" "${family}")" \
       != "$(parse total "${TMP_DIR}/metrics-off.txt" "${family}")" ]; then
    fail "B.total" "${family}: sum() differs between the split and the 0.18.0 shape"
    B_FAILED=1
  fi
done
[ "${B_FAILED}" -eq 0 ] \
  && pass "B" "the split is exact on all five families: same sum by (service), same sum()"

step "D. per_grouping_labels = false restores the 0.18.0 shape"
D_FAILED=0
for family in ${FAMILIES_COUNTER} ${FAMILY_HISTOGRAM}; do
  # Prometheus stores an empty label value as no label at all, so an empty
  # grouping on every series IS the 0.18.0 identity, not a blank-tagged one.
  named="$(parse groupings "${TMP_DIR}/metrics-off.txt" "${family}" | grep -c .)"
  if [ "${named}" -ne 0 ]; then
    fail "D.empty" "${family} still carries ${named} non-empty grouping value(s) with the knob off"
    D_FAILED=1
  fi
done
# The asymmetry the knob was added for: `per_service_labels = false` blanks
# `service` on the findings counter and the histogram, but NOT on the three
# I/O counters, which only `per_grouping_labels` reaches.
start_daemon false true svcoff || die "per_service_labels=false daemon failed to start"
scrape "${TMP_DIR}/metrics-startup-svcoff.txt"
phase_split "${TMP_DIR}/metrics-svcoff.txt"
for family in perf_sentinel_service_avoidable_io_ops_total \
              perf_sentinel_service_analyzed_io_ops_total \
              perf_sentinel_service_io_ops_total; do
  named="$(parse services "${TMP_DIR}/metrics-svcoff.txt" "${family}" | grep -c '^gms-')"
  if [ "${named}" -lt 1 ]; then
    fail "D.asymmetry" "${family} lost its service under per_service_labels=false; only per_grouping_labels should reach it"
    D_FAILED=1
  fi
done
if [ "$(parse services "${TMP_DIR}/metrics-svcoff.txt" perf_sentinel_findings_total | tr -d '\n')" != "" ]; then
  fail "D.asymmetry" "perf_sentinel_findings_total kept a service under per_service_labels=false"
  D_FAILED=1
fi
# Startup rule that changed with the knob: the histogram's unlabelled series is
# minted at startup only when BOTH knobs are off. With per_service_labels=false
# alone it now appears with the first slow span instead, which is the easiest
# thing here to break without noticing.
start_daemon false false bothoff || die "both-off daemon failed to start"
scrape "${TMP_DIR}/metrics-startup-bothoff.txt"
warm_bothoff="$(parse series "${TMP_DIR}/metrics-startup-bothoff.txt" "${FAMILY_HISTOGRAM}" | grep -c .)"
warm_svcoff="$(parse series "${TMP_DIR}/metrics-startup-svcoff.txt" "${FAMILY_HISTOGRAM}" | grep -c .)"
if [ "${warm_bothoff}" -lt 1 ]; then
  fail "D.prewarm" "both knobs off did not pre-warm the unlabelled histogram series"
  D_FAILED=1
elif [ "${warm_svcoff}" -ne 0 ]; then
  fail "D.prewarm" "per_service_labels=false alone pre-warmed ${warm_svcoff} histogram series; since 0.19.0 only both-off does"
  D_FAILED=1
fi
[ "${D_FAILED}" -eq 0 ] \
  && pass "D" "the knob empties all five families, spares service on the I/O counters, and pre-warms only with both knobs off"

step "C. past the pair caps the grouping folds into _other and the service survives"
# Two saturation loops: the labelled one that folds, and the same traffic into
# a knob-off daemon, which never folds because the empty grouping is reserved
# and takes no slot. The second is the reference the invariant is read against.
saturate() {  # $1 = output metrics file
  local i
  for i in $(seq 1 "${SAT_ITERATIONS}"); do
    send "ns-$i" "${SAT_SERVICES}" "${SAT_SERVICES}" 1 sat
  done
  sleep 8
  scrape "$1"
}
start_daemon true true sat || die "saturation daemon failed to start"
saturate "${TMP_DIR}/metrics-sat-on.txt"
C_FAILED=0

analysis_of="$(counter_value "${TMP_DIR}/metrics-sat-on.txt" perf_sentinel_analysis_grouping_overflow_total)"
hist_of="$(counter_value "${TMP_DIR}/metrics-sat-on.txt" perf_sentinel_slow_duration_grouping_overflow_total)"
ingest_of="$(counter_value "${TMP_DIR}/metrics-sat-on.txt" perf_sentinel_service_io_ops_grouping_overflow_total)"
for pair in "analysis:${analysis_of}" "histogram:${hist_of}" "ingest:${ingest_of}"; do
  if [ "${pair#*:}" = "0" ] || [ "${pair#*:}" = "0.0" ]; then
    fail "C.overflow" "the ${pair%%:*} grouping overflow counter never moved; the cap was not reached, raise SAT_ITERATIONS"
    C_FAILED=1
  fi
done

# The service axis must be untouched: 40 services is under every service cap,
# so anything folded here folded on the grouping axis alone.
for metric in perf_sentinel_analysis_service_overflow_total \
              perf_sentinel_slow_duration_service_overflow_total \
              perf_sentinel_service_io_ops_overflow_total; do
  v="$(counter_value "${TMP_DIR}/metrics-sat-on.txt" "${metric}")"
  if [ "${v}" != "0" ] && [ "${v}" != "0.0" ]; then
    fail "C.axis" "${metric} moved to ${v}; the service axis folded too and the legs below would not isolate the grouping cap"
    C_FAILED=1
  fi
done

for family in ${FAMILIES_COUNTER} ${FAMILY_HISTOGRAM}; do
  # A folded pair keeps its service: `_other` must appear as a grouping and
  # never as a service.
  if ! parse groupings "${TMP_DIR}/metrics-sat-on.txt" "${family}" | grep -qx "_other"; then
    fail "C.fold" "${family} has no grouping=\"_other\" after saturation"
    C_FAILED=1
  fi
  if parse services "${TMP_DIR}/metrics-sat-on.txt" "${family}" | grep -qx "_other"; then
    fail "C.fold" "${family} folded a SERVICE into _other; only the grouping should fold"
    C_FAILED=1
  fi
  # The bound is on (service, grouping) PAIRS, not on either axis alone, so it
  # is pairs that are counted here. `_other` is reserved and takes no slot,
  # which is why it is excluded rather than counted against the cap.
  case "${family}" in
    perf_sentinel_service_io_ops_total)   cap=${CAP_INGEST_PAIRS} ;;
    perf_sentinel_slow_duration_seconds)  cap=${CAP_HISTOGRAM_PAIRS} ;;
    *)                                    cap=${CAP_ANALYSIS_PAIRS} ;;
  esac
  admitted="$(parse pairs "${TMP_DIR}/metrics-sat-on.txt" "${family}" \
    | grep -v "$(printf '\t')_other\$" | grep -c .)"
  if [ "${admitted}" -gt "${cap}" ]; then
    fail "C.cap" "${family} admitted ${admitted} (service, grouping) pairs, past its documented cap of ${cap}"
    C_FAILED=1
  fi
done

start_daemon true false satoff || die "knob-off saturation daemon failed to start"
saturate "${TMP_DIR}/metrics-sat-off.txt"
# The invariant of leg B, re-read under folding, on the two families that count
# I/O ops directly. The other three are derived from findings and inherit their
# run-to-run variance, which the 0.19.0 validation measured rather than assumed:
# over a multi-minute stream the analysis worker batches differently from one
# run to the next, `findings_total` moved by up to 16 out of ~7100 between two
# runs of the same traffic at the same knob setting, and
# `service_avoidable_io_ops_total`, being a per-finding share, moved with it.
# `service_analyzed_io_ops_total` and `service_io_ops_total` were identical to
# the unit across every run, loaded machine included. That variance is not the
# fold, so pinning those three here would make the leg flaky for a reason it
# does not test. They are covered instead where they are stable: leg B compares
# all five exactly on short runs, and the ratio check below reads the avoidable
# counter against its own denominator inside a single run.
for family in perf_sentinel_service_analyzed_io_ops_total \
              perf_sentinel_service_io_ops_total; do
  if ! diff -q <(parse sumsvc "${TMP_DIR}/metrics-sat-on.txt" "${family}") \
               <(parse sumsvc "${TMP_DIR}/metrics-sat-off.txt" "${family}") >/dev/null; then
    fail "C.invariant" "${family}: folding into _other changed sum by (service)"
    diff <(parse sumsvc "${TMP_DIR}/metrics-sat-on.txt" "${family}") \
         <(parse sumsvc "${TMP_DIR}/metrics-sat-off.txt" "${family}") | head -6
    C_FAILED=1
  fi
done
# The avoidable counter read against its own denominator, inside one scrape, so
# no cross-run comparison is involved. Both are charged under the same
# (service, grouping) key by the same meter, including once a pair folds into
# `_other`, so a ratio above 1 would mean the fold charged a numerator to a
# pair whose denominator went elsewhere.
if ! python3 - "${SCENARIO_DIR}" "${TMP_DIR}/metrics-sat-on.txt" <<'PY'
import subprocess, sys
scenario_dir, metrics = sys.argv[1], sys.argv[2]

def series(family):
    out = subprocess.run(
        [sys.executable, f"{scenario_dir}/parse_metrics.py", "series", metrics, family],
        capture_output=True, text=True, check=True).stdout
    parsed = {}
    for line in out.splitlines():
        labels, _, value = line.rpartition(" ")
        parsed[labels] = float(value)
    return parsed

numerator = series("perf_sentinel_service_avoidable_io_ops_total")
denominator = series("perf_sentinel_service_analyzed_io_ops_total")
over = [
    (key, value, denominator.get(key))
    for key, value in numerator.items()
    if not denominator.get(key) or value > denominator[key]
]
if over:
    print(f"{len(over)} pair(s) with avoidable > analysed, first: {over[0]}", file=sys.stderr)
    sys.exit(1)
print(f"{len(numerator)} pairs checked")
PY
then
  fail "C.ratio" "a (service, grouping) pair reports more avoidable than analysed I/O ops after folding"
  C_FAILED=1
fi
[ "${C_FAILED}" -eq 0 ] \
  && pass "C" "all three caps folded the grouping only, kept every service, and preserved sum by (service)"

step "Summary"
VERDICT="PASS"; [ "${FAILURES}" -gt 0 ] && VERDICT="FAIL"
{
  echo "# perf-sentinel grouping metric split"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Binary: ${VERSION} (${PRODUCT_COMMIT})"
  echo "Saturation: ${SAT_ITERATIONS} groupings x ${SAT_SERVICES} services"
  echo
  echo "| check | verdict | evidence |"
  echo "|---|---|---|"
  for row in "${RESULTS[@]}"; do
    IFS='|' read -r name verdict note <<<"${row}"
    printf '| %s | %s | %s |\n' "${name}" "${verdict}" "${note}"
  done
  echo
  echo "Overflow counters after saturation: analysis=${analysis_of:-n/a}, histogram=${hist_of:-n/a}, ingest=${ingest_of:-n/a}"
  echo
  echo "**Verdict: ${VERDICT}**"
} > "${REPORT}"

if [ "${VERDICT}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
fi
die "${FAILURES} grouping metric assertion(s) failed, see ${REPORT}"
