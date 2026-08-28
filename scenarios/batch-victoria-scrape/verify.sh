#!/usr/bin/env bash
# batch over Victoria Traces, through the Jaeger query API.
#
# Use case: the trace backend is Victoria Traces rather than Tempo, and a
# periodic batch job fetches recent traces and runs detection on them.
#
# Tests `perf-sentinel jaeger-query --endpoint ...` end to end. Two things
# make this scenario different from its Tempo twin, and both are the reason
# it exists:
#
#   1. The endpoint carries a path. Victoria Traces serves the Jaeger query
#      API under /select/jaeger, not at the root, so `--endpoint` ends with
#      that prefix and the CLI appends /api/traces to it.
#
#   2. The window has to be PROVEN, not assumed. Until 0.16.0 the CLI sent
#      the window as `lookback`, which Victoria Traces reads only on its
#      service-graph endpoint and never on /api/traces. The parameter was
#      dropped and every search ran from the Unix epoch. An assertion that
#      only checks "findings came back" would have passed against that bug,
#      because an epoch-wide search returns the same traces. Leg B below is
#      the discriminating one: it asks for a window that EXCLUDES the
#      traffic and requires an empty result.

set -euo pipefail

SCENARIO="batch-victoria-scrape"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
HOST_FROM_CONTAINER="host.docker.internal"
VT_URL_HOST="${VT_URL_HOST:-http://localhost:10428}"
# The Jaeger prefix belongs to the endpoint: the CLI appends /api/traces.
VT_QUERY_IN_CONTAINER="http://${HOST_FROM_CONTAINER}:10428/select/jaeger"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"
findings_count=0
abs_findings_count=0
window_honoured="no"
PF_ORDER_PID=""

cleanup() {
  [ -z "${PF_ORDER_PID}" ] || kill "${PF_ORDER_PID}" 2>/dev/null || true
}
trap cleanup EXIT

run_jaeger_query() {
  # $1 output file, rest are extra CLI arguments.
  local out="$1"; shift
  docker run --rm \
    --add-host "${HOST_FROM_CONTAINER}:host-gateway" \
    "${IMAGE}" \
    jaeger-query \
      --endpoint "${VT_QUERY_IN_CONTAINER}" \
      --service order-service \
      --max-traces 50 \
      --format json \
      "$@" \
    > "${out}" 2> "${out%.json}.log"
}

step "Probe Victoria Traces from host"
ready=0
for i in $(seq 1 30); do
  if curl -fsS "${VT_URL_HOST}/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "${ready}" != "1" ]; then
  die "Victoria Traces not reachable at ${VT_URL_HOST} after 60s, run scripts/port-forward.sh start"
fi
ok "Victoria Traces ready"

step "Generate recent N+1 traffic"
TRAFFIC_START=$(date -u +%s)
kubectl -n shop port-forward svc/order-service 18281:8080 \
  > "${TMP_DIR}/pf-order.log" 2>&1 &
PF_ORDER_PID=$!
for i in $(seq 1 15); do
  curl -fsS "http://localhost:18281/actuator/health" >/dev/null 2>&1 && break
  sleep 1
done
for i in $(seq 1 3); do
  curl -fsS -X POST "http://localhost:18281/api/fault/n-plus-one-sql?items=15" >/dev/null
done
kill "${PF_ORDER_PID}" 2>/dev/null || true
wait "${PF_ORDER_PID}" 2>/dev/null || true
PF_ORDER_PID=""

# Wait for the N+1 traces specifically, not for any trace. This service is
# also probed by the readiness loop above and scraped by Prometheus, and both
# produce single-span traces that the backend returns first because they are
# the most recent. Waiting on "any data" would let the scenario proceed while
# only that noise is visible, which is what --max-traces then fetches.
indexed=0
for i in $(seq 1 30); do
  now_us=$(( $(date -u +%s) * 1000000 ))
  start_us=$(( now_us - 120000000 ))
  if curl -fsS "${VT_URL_HOST}/select/jaeger/api/traces?service=order-service&start=${start_us}&end=${now_us}&limit=50" \
       | python3 -c 'import json,sys; sys.exit(not any(len(t.get("spans", [])) > 5 for t in json.load(sys.stdin).get("data") or []))' 2>/dev/null; then
    indexed=1
    break
  fi
  sleep 2
done
[ "${indexed}" = "1" ] || die "targeted traces were not indexed by Victoria Traces after 60s"
ok "targeted traces indexed"
TRAFFIC_END=$(date -u +%s)

step "Leg A: relative window (--lookback 5m)"
if run_jaeger_query "${TMP_DIR}/relative.json" --lookback 5m; then
  findings_count=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/relative.json')).get('findings', [])))" 2>/dev/null || echo 0)
  traces_relative=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/relative.json')).get('analysis', {}).get('traces_analyzed', 0))" 2>/dev/null || echo 0)
  ok "relative window: ${findings_count} findings from ${traces_relative} traces"
else
  tail -5 "${TMP_DIR}/relative.log"
  verdict="FAIL"
  color_red "    fail: jaeger-query exited non-zero on a relative window"
fi

step "Leg B: a window that excludes the traffic must come back empty"
# One hour, ending an hour before the traffic. If the window reaches the
# backend at all, nothing can match it. If the window is dropped, the search
# runs unbounded and returns the traffic, which is the pre-0.16.0 bug.
EXCL_TO=$(( TRAFFIC_START - 3600 ))
EXCL_FROM=$(( EXCL_TO - 3600 ))
iso() { python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
EXCL_FROM_ISO="$(iso "${EXCL_FROM}")"
EXCL_TO_ISO="$(iso "${EXCL_TO}")"
if run_jaeger_query "${TMP_DIR}/excluded.json" --from "${EXCL_FROM_ISO}" --to "${EXCL_TO_ISO}"; then
  excluded_traces=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/excluded.json')).get('analysis', {}).get('traces_analyzed', 0))" 2>/dev/null || echo 0)
  color_red "    fail: a window before the traffic returned ${excluded_traces} traces, the bounds were ignored"
  verdict="FAIL"
elif grep -qi "no traces found" "${TMP_DIR}/excluded.log"; then
  window_honoured="yes"
  ok "excluded window returned no traces, the bounds reached the backend"
else
  tail -5 "${TMP_DIR}/excluded.log"
  color_red "    fail: excluded window failed for a reason other than an empty result"
  verdict="FAIL"
fi

step "Leg C: absolute window framing the traffic"
ABS_FROM_ISO="$(iso $(( TRAFFIC_START - 60 )))"
ABS_TO_ISO="$(iso $(( TRAFFIC_END + 60 )))"
if run_jaeger_query "${TMP_DIR}/absolute.json" --from "${ABS_FROM_ISO}" --to "${ABS_TO_ISO}"; then
  abs_findings_count=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/absolute.json')).get('findings', [])))" 2>/dev/null || echo 0)
  abs_traces=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/absolute.json')).get('analysis', {}).get('traces_analyzed', 0))" 2>/dev/null || echo 0)
  ok "absolute window: ${abs_findings_count} findings from ${abs_traces} traces"
else
  tail -5 "${TMP_DIR}/absolute.log"
  verdict="FAIL"
  color_red "    fail: jaeger-query exited non-zero on an absolute window"
fi

step "Verdict"
if [ "${verdict}" != "FAIL" ]; then
  grouping_ok=$(python3 -c "
import json
findings=json.load(open('${TMP_DIR}/absolute.json')).get('findings', [])
print('yes' if findings and all(
    f.get('grouping') and f['grouping'][0] == {'key':'k8s.namespace.name','value':'shop'}
    for f in findings) else 'no')" 2>/dev/null || echo no)
  if [ "${findings_count}" -gt 0 ] && [ "${abs_findings_count}" -gt 0 ] \
     && [ "${window_honoured}" = "yes" ] && [ "${grouping_ok}" = "yes" ]; then
    verdict="PASS"
    ok "both window forms honoured, findings grouped by k8s.namespace.name=shop"
  else
    verdict="FAIL"
    color_red "    fail: relative=${findings_count}, absolute=${abs_findings_count}, bounded=${window_honoured}, grouping=${grouping_ok}"
  fi
fi

step "Write report"
{
  echo "# batch over Victoria Traces (Jaeger query API)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Image: ${IMAGE}"
  echo "Victoria Traces: ${VT_URL_HOST} (query prefix: ${VT_QUERY_IN_CONTAINER})"
  echo
  echo "## What this proves"
  echo
  echo "Leg B is the load-bearing one. It asks for a window that ends an hour"
  echo "before the traffic was generated and requires an empty result. Before"
  echo "0.16.0 the CLI sent the window as \`lookback\`, which this backend reads"
  echo "only on its service-graph endpoint, so the search ran from the Unix"
  echo "epoch and would have returned the traffic anyway."
  echo
  echo "| Leg | Window | Result |"
  echo "|---|---|---|"
  echo "| A relative | \`--lookback 5m\` | ${findings_count} findings |"
  echo "| B excluded | \`--from ${EXCL_FROM_ISO} --to ${EXCL_TO_ISO}\` | bounded: ${window_honoured} |"
  echo "| C absolute | \`--from ${ABS_FROM_ISO} --to ${ABS_TO_ISO}\` | ${abs_findings_count} findings |"
  echo
  echo "## Verdict"
  echo
  echo "${verdict}"
} > "${REPORT}"
ok "report at ${REPORT}"

[ "${verdict}" = "PASS" ] || die "scenario failed"
color_green "PASS"
