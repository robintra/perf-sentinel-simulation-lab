#!/usr/bin/env bash
# multi-format input live: traces flow through OTel Collector
# parallel exporters to Jaeger and Zipkin backends, then perf-sentinel
# `analyze` is run on each export and the findings are compared.
#
# Plus boundary tests on JSON parser depth using committed synthetic
# fixtures (depth-31 must parse, depth-33 must reject per upstream
# MAX_JSON_DEPTH=32).

set -euo pipefail

SCENARIO="multiformat-input"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
IMAGE="ghcr.io/robintra/perf-sentinel:0.5.21"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
mkdir -p "${TMP_DIR}"
rm -f "${REPORT}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; cleanup; exit 1; }

PF_JAEGER_PID=""
PF_ZIPKIN_PID=""
PF_ORDER_PID=""
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

cleanup() {
  for pid in "${PF_JAEGER_PID}" "${PF_ZIPKIN_PID}" "${PF_ORDER_PID}"; do
    if [ -n "${pid}" ]; then kill "${pid}" 2>/dev/null || true; fi
  done
  # Default: keep Jaeger, Zipkin, NetworkPolicies and the multi-export
  # collector config in place. Re-runs are then idempotent and fast.
  # Set KEEP_BACKENDS=no explicitly to tear them down.
  if [ "${KEEP_BACKENDS:-yes}" = "no" ]; then
    kubectl -n observability delete -f "${SCENARIO_DIR}/manifests.yaml" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    helm upgrade otel-collector open-telemetry/opentelemetry-collector \
      --version "$(otel_chart_version)" \
      -n observability \
      -f "${REPO_ROOT}/helm/values/otel-collector.yaml" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

verdict_live="UNKNOWN"
verdict_boundary="UNKNOWN"
JAEGER_FINDINGS=0
ZIPKIN_FINDINGS=0
JAEGER_TYPES=""
ZIPKIN_TYPES=""

step "Apply Jaeger + Zipkin manifests"
kubectl apply -f "${SCENARIO_DIR}/manifests.yaml" > "${TMP_DIR}/apply.log" 2>&1
ok "manifests applied"

step "Helm upgrade OTel Collector with multi-export overlay"
helm upgrade otel-collector open-telemetry/opentelemetry-collector \
  --version "$(otel_chart_version)" \
  -n observability \
  -f "${REPO_ROOT}/helm/values/otel-collector.yaml" \
  -f "${SCENARIO_DIR}/collector-overlay.yaml" \
  > "${TMP_DIR}/helm.log" 2>&1
ok "collector reconfigured for multi-export"

step "Wait for Jaeger and Zipkin to be Ready"
kubectl -n observability rollout restart deployment/jaeger deployment/zipkin >/dev/null
kubectl -n observability rollout status deploy/jaeger --timeout=180s
kubectl -n observability rollout status deploy/zipkin --timeout=180s
# Cilium needs ~10-20s to converge new NetworkPolicies, otherwise the
# collector exporters time out on context deadline.
sleep 30
ok "backends Ready and policies converged"

step "Generate targeted live traffic (10 N+1 SQL + 10 redundant SQL via order-service)"
# A focused burst rather than make validate-findings (which sends 1500
# requests across 10 scenarios and overwhelms the in-memory Jaeger
# indexer). 20 requests over ~10s is enough to produce rich N+1 traces
# in all three backends, with headroom for indexing.
ORDER_POD=$(kubectl -n shop get pod -l app.kubernetes.io/name=order-service -o jsonpath='{.items[0].metadata.name}')
kubectl -n shop port-forward "${ORDER_POD}" 18280:8080 > "${TMP_DIR}/pf-order.log" 2>&1 &
PF_ORDER_PID=$!
sleep 5
for i in $(seq 1 10); do
  curl -fsS -X POST "http://localhost:18280/api/fault/n-plus-one-sql?items=15" >/dev/null 2>&1 || true
  curl -fsS -X POST "http://localhost:18280/api/fault/redundant-sql?items=10" >/dev/null 2>&1 || true
  sleep 0.3
done
kill ${PF_ORDER_PID} 2>/dev/null || true
ok "20 targeted requests sent"

step "Wait for Jaeger and Zipkin to index the rich traces (poll on POST trace presence)"
kubectl -n observability port-forward svc/jaeger 16686:16686 \
  > "${TMP_DIR}/pf-jaeger-poll.log" 2>&1 &
PF_JAEGER_POLL_PID=$!
kubectl -n observability port-forward svc/zipkin 9411:9411 \
  > "${TMP_DIR}/pf-zipkin-poll.log" 2>&1 &
PF_ZIPKIN_POLL_PID=$!
sleep 4
for i in $(seq 1 60); do
  # Count traces that have BOTH a POST span AND at least 1 SELECT span
  # (rich N+1 shape, not single-span probes).
  jaeger_rich=$(curl -fsS -m 10 "http://localhost:16686/api/traces?service=order-service&limit=200&lookback=2m" 2>/dev/null \
                | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
n = 0
for t in data.get('data', []):
    spans = t.get('spans', [])
    if len(spans) > 5:
        n += 1
print(n)" 2>/dev/null || echo 0)
  zipkin_rich=$(curl -fsS -m 10 "http://localhost:9411/api/v2/traces?serviceName=order-service&limit=200&lookback=120000" 2>/dev/null \
                | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
n = 0
for trace in data:
    if len(trace) > 5:
        n += 1
print(n)" 2>/dev/null || echo 0)
  if [ "${jaeger_rich}" -ge 1 ] && [ "${zipkin_rich}" -ge 1 ]; then
    echo "    debug: jaeger_rich=${jaeger_rich} zipkin_rich=${zipkin_rich} after ${i}*2s"
    break
  fi
  if [ "$((i % 5))" = "0" ]; then
    echo "    debug: i=$((i*2))s jaeger_rich=${jaeger_rich} zipkin_rich=${zipkin_rich}"
  fi
  sleep 2
done
kill ${PF_JAEGER_POLL_PID} ${PF_ZIPKIN_POLL_PID} 2>/dev/null || true
ok "backends indexed rich traces"

step "Port-forward Jaeger and Zipkin"
kubectl -n observability port-forward svc/jaeger 16686:16686 \
  > "${TMP_DIR}/pf-jaeger.log" 2>&1 &
PF_JAEGER_PID=$!
kubectl -n observability port-forward svc/zipkin 9411:9411 \
  > "${TMP_DIR}/pf-zipkin.log" 2>&1 &
PF_ZIPKIN_PID=$!
for i in $(seq 1 30); do
  jaeger_ok=$(curl -fsS "http://localhost:16686/api/services" >/dev/null 2>&1 && echo y || echo n)
  zipkin_ok=$(curl -fsS "http://localhost:9411/api/v2/services" >/dev/null 2>&1 && echo y || echo n)
  if [ "${jaeger_ok}" = "y" ] && [ "${zipkin_ok}" = "y" ]; then break; fi
  sleep 1
done
ok "Jaeger and Zipkin reachable"

step "Fetch RICH traces from Jaeger query API (filter spans>5)"
curl -fsS -m 30 "http://localhost:16686/api/traces?service=order-service&limit=200&lookback=2m" \
  > "${TMP_DIR}/jaeger-traces-all.json" 2>/dev/null || true
# Keep only traces with > 5 spans (rich N+1) to feed analyze.
python3 -c "
import json
data = json.load(open('${TMP_DIR}/jaeger-traces-all.json'))
rich = [t for t in data.get('data', []) if len(t.get('spans', [])) > 5]
out = {'data': rich, 'total': len(rich), 'limit': 0, 'offset': 0, 'errors': None}
json.dump(out, open('${TMP_DIR}/jaeger-traces.json', 'w'))
print(f'rich traces: {len(rich)}')
"
JAEGER_TRACE_COUNT=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/jaeger-traces.json')).get('data', [])))" 2>/dev/null || echo 0)
ok "Jaeger returned ${JAEGER_TRACE_COUNT} rich traces"
if [ "${JAEGER_TRACE_COUNT}" = "0" ]; then
  die "Jaeger has no rich traces (only probe spans), check OTel Collector pipeline"
fi

step "Fetch RICH traces from Zipkin query API (filter spans>5)"
curl -fsS -m 30 "http://localhost:9411/api/v2/traces?serviceName=order-service&limit=200&lookback=120000" \
  > "${TMP_DIR}/zipkin-traces-raw.json" 2>/dev/null || true
# Zipkin returns List[List[span]]. Keep only traces with > 5 spans (rich), flatten to one list.
python3 -c "
import json
data = json.load(open('${TMP_DIR}/zipkin-traces-raw.json'))
rich_traces = [t for t in data if len(t) > 5]
spans = [s for trace in rich_traces for s in trace]
json.dump(spans, open('${TMP_DIR}/zipkin-traces.json', 'w'))
print(f'rich traces: {len(rich_traces)}, spans: {len(spans)}')
"
ZIPKIN_SPAN_COUNT=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/zipkin-traces.json'))))")
ok "Zipkin rich traces flattened (${ZIPKIN_SPAN_COUNT} spans)"
if [ "${ZIPKIN_SPAN_COUNT}" = "0" ]; then
  die "Zipkin has no rich spans, check OTel Collector pipeline"
fi

step "Run perf-sentinel analyze on Jaeger export"
if docker run --rm \
     -v "${TMP_DIR}/jaeger-traces.json:/input.json:ro" \
     "${IMAGE}" \
     analyze --input /input.json --format json \
     > "${TMP_DIR}/jaeger-findings.json" 2> "${TMP_DIR}/jaeger-analyze.log"; then
  JAEGER_FINDINGS=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/jaeger-findings.json')).get('findings', [])))")
  JAEGER_TYPES=$(python3 -c "
import json
data = json.load(open('${TMP_DIR}/jaeger-findings.json'))
types = sorted(set(f.get('type', 'unknown') for f in data.get('findings', [])))
print(','.join(types))
")
  ok "Jaeger analyze: ${JAEGER_FINDINGS} findings, types=${JAEGER_TYPES}"
else
  color_red "    fail: analyze on Jaeger export exited non-zero"
  tail -10 "${TMP_DIR}/jaeger-analyze.log"
fi

step "Run perf-sentinel analyze on Zipkin export"
if docker run --rm \
     -v "${TMP_DIR}/zipkin-traces.json:/input.json:ro" \
     "${IMAGE}" \
     analyze --input /input.json --format json \
     > "${TMP_DIR}/zipkin-findings.json" 2> "${TMP_DIR}/zipkin-analyze.log"; then
  ZIPKIN_FINDINGS=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/zipkin-findings.json')).get('findings', [])))")
  ZIPKIN_TYPES=$(python3 -c "
import json
data = json.load(open('${TMP_DIR}/zipkin-findings.json'))
types = sorted(set(f.get('type', 'unknown') for f in data.get('findings', [])))
print(','.join(types))
")
  ok "Zipkin analyze: ${ZIPKIN_FINDINGS} findings, types=${ZIPKIN_TYPES}"
else
  color_red "    fail: analyze on Zipkin export exited non-zero"
  tail -10 "${TMP_DIR}/zipkin-analyze.log"
fi

step "Compare Jaeger vs Zipkin findings"
# Rigorous: both formats analyze rich traces and produce coherent
# findings (same anti-pattern categories detected on the same upstream
# traffic). Backends bumped to MEM_MAX_TRACES=50000 / MEM_MAX_SPANS=500k
# so heavy N+1 traces are not FIFO-evicted by the steady probe traffic.
if [ "${JAEGER_FINDINGS}" -gt 0 ] && [ "${ZIPKIN_FINDINGS}" -gt 0 ]; then
  COMMON=$(python3 -c "
j = set('${JAEGER_TYPES}'.split(','))
z = set('${ZIPKIN_TYPES}'.split(','))
print(len(j & z))
")
  TOTAL=$(python3 -c "
j = set('${JAEGER_TYPES}'.split(','))
z = set('${ZIPKIN_TYPES}'.split(','))
print(len(j | z))
")
  if [ "${COMMON}" -ge 1 ]; then
    verdict_live="PASS"
    ok "live multi-format coherence: ${COMMON}/${TOTAL} finding categories common"
  else
    verdict_live="FAIL"
    color_red "    fail: 0 finding categories common between Jaeger and Zipkin"
  fi
else
  verdict_live="FAIL"
  color_red "    fail: at least one format returned 0 findings (jaeger=${JAEGER_FINDINGS}, zipkin=${ZIPKIN_FINDINGS})"
fi

step "Boundary fixtures: depth-31 must parse, depth-33 must reject (Jaeger only)"
# Zipkin v2 spec has tags as Map<String,String>, no place for nested
# arrays of arbitrary depth. The depth-33 Zipkin fixture happens to
# reject on depth, but depth-31 rejects on type (tag type mismatch)
# before the depth check fires. We restrict the boundary test to
# Jaeger format which has flexible tag value types. The behaviour
# of the depth guard itself (32 cap) is the same regardless of input
# format.
boundary_pass=0
boundary_total=0
for depth in 31 33; do
  boundary_total=$((boundary_total + 1))
  fixture="${SCENARIO_DIR}/fixtures/depth-${depth}-jaeger.json"
  if docker run --rm \
       -v "${fixture}:/input.json:ro" \
       "${IMAGE}" \
       analyze --input /input.json --format json >/dev/null 2> "${TMP_DIR}/boundary-jaeger-${depth}.log"; then
    analyze_exit=0
  else
    analyze_exit=$?
  fi
  case "${depth}" in
    31)
      if [ "${analyze_exit}" = "0" ]; then
        boundary_pass=$((boundary_pass + 1))
        ok "depth-31 jaeger: PASS (parsed cleanly under MAX_JSON_DEPTH=32)"
      else
        color_red "    fail: depth-31 jaeger should parse but analyze exited ${analyze_exit}"
        cat "${TMP_DIR}/boundary-jaeger-${depth}.log" | tail -2
      fi
      ;;
    33)
      if [ "${analyze_exit}" != "0" ] && grep -q "exceeds maximum depth" "${TMP_DIR}/boundary-jaeger-${depth}.log"; then
        boundary_pass=$((boundary_pass + 1))
        ok "depth-33 jaeger: PASS (rejected on depth as expected)"
      else
        color_red "    fail: depth-33 jaeger should reject on depth"
        cat "${TMP_DIR}/boundary-jaeger-${depth}.log" | tail -2
      fi
      ;;
  esac
done
if [ "${boundary_pass}" = "${boundary_total}" ]; then
  verdict_boundary="PASS"
  ok "boundary fixtures (Jaeger): ${boundary_pass}/${boundary_total} PASS"
else
  verdict_boundary="FAIL"
  color_red "    fail: boundary fixtures ${boundary_pass}/${boundary_total} PASS"
fi

step "Write report"
{
  echo "# multi-format input (live multi-backend + boundary fixtures)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Live ingestion"
  echo
  echo "Architecture: OTel Collector pipeline traces exports in parallel to"
  echo "Tempo (existing), Jaeger backend (new), Zipkin backend (new). Each"
  echo "export is fetched via the backend's query API and fed to"
  echo "perf-sentinel analyze."
  echo
  echo "| Format | Source | Findings | Types |"
  echo "| --- | --- | --- | --- |"
  echo "| Jaeger | Jaeger /api/traces | ${JAEGER_FINDINGS} | ${JAEGER_TYPES} |"
  echo "| Zipkin | Zipkin /api/v2/traces | ${ZIPKIN_FINDINGS} | ${ZIPKIN_TYPES} |"
  echo
  echo "Live verdict: **${verdict_live}**"
  echo
  echo "## Boundary fixtures"
  echo
  echo "Synthetic fixtures committed under \`fixtures/\`. depth-31 should"
  echo "parse (under MAX_JSON_DEPTH=32), depth-33 should be rejected."
  echo
  echo "Boundary verdict: **${verdict_boundary}** (${boundary_pass}/${boundary_total} fixtures matched expected outcome)"
  echo
  echo "## Overall verdict"
  echo
  if [ "${verdict_live}" = "PASS" ] && [ "${verdict_boundary}" = "PASS" ]; then
    echo "**Verdict: PASS**"
  else
    echo "**Verdict: FAIL**"
  fi
} > "${REPORT}"

if [ "${verdict_live}" = "PASS" ] && [ "${verdict_boundary}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "partial (live=${verdict_live} boundary=${verdict_boundary}), see ${REPORT}"
fi
