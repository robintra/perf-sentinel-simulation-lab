#!/usr/bin/env bash
# limit-multi-source: all live ingestion paths under concurrent load.
# A scoped daemon (own namespace) takes OTLP gRPC + OTLP HTTP + Unix NDJSON
# socket simultaneously while the host runs `perf-sentinel tempo` against
# the lab Tempo as the concurrent batch reader.
#
# Asserts:
#   - otlp_spans_received_total delta ~= spans sent by the gRPC + HTTP Jobs
#     (±10%; the NDJSON socket bypasses the OTLP counters by design,
#     documented feedback: no received counter on that path);
#   - no source starves: services from all three live prefixes (g-, h-, n-)
#     appear in /api/export/report;
#   - filtered{not_io} delta == 0 (the generator emits only I/O spans:
#     harness self-check);
#   - the tempo batch subcommand exits 0 under load in < 120s;
#   - the scoped daemon never restarts.
set -euo pipefail

SCENARIO="limit-multi-source"
NS="limit-multi-source"
DEPLOY="multi-source-daemon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
mkdir -p "${TMP_DIR}"

# Not 24318: crates/sentinel-cli/tests/e2e/watch.rs binds 24317 and 24318 for
# its own listeners, so a cargo test run against the engine checkout while this
# scenario holds its forward failed to bind with an address-in-use naming
# neither side.
LOCAL_PORT="${LOCAL_PORT:-24328}"
ENDPOINT="http://localhost:${LOCAL_PORT}"
LOAD_SECONDS="${LOAD_SECONDS:-180}"
TPS="${TPS:-30}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
TEMPO_LOCAL_PORT="${TEMPO_LOCAL_PORT:-3200}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

cleanup() {
  pkill -f "kubectl.*port-forward.*${DEPLOY}" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*tempo.*${TEMPO_LOCAL_PORT}" 2>/dev/null || true
  kubectl delete namespace "${NS}" --ignore-not-found --timeout=90s >/dev/null 2>&1 || true
}
trap cleanup EXIT

metric_val() {
  awk -v m="$1" '$1==m {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
labeled_metric_val() {
  awk -v m="$1" '$0 ~ "^"m" " {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
snapshot_metrics() { curl -fsS --max-time 5 "${ENDPOINT}/metrics" > "${TMP_DIR}/metrics.txt"; }
daemon_restarts() {
  kubectl -n "${NS}" get pod -l "app.kubernetes.io/name=${DEPLOY}" \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="daemon")].restartCount}' 2>/dev/null || echo 0
}

# =============================================================================
step "Deploy the scoped multi-source daemon (same image as the main daemon)"
DAEMON_IMAGE="$(kubectl -n observability get deploy perf-sentinel-daemon \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ -n "${DAEMON_IMAGE}" ] || die "cannot read the main daemon image"
sed "s|PLACEHOLDER_DAEMON_IMAGE|${DAEMON_IMAGE}|" "${SCRIPT_DIR}/manifests.yaml" | kubectl apply -f - >/dev/null
kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null || die "scoped daemon rollout failed"
kubectl -n "${NS}" port-forward "deploy/${DEPLOY}" "${LOCAL_PORT}:14318" >/dev/null 2>&1 &
sleep 3
curl -fsS "${ENDPOINT}/api/status" >/dev/null || die "scoped daemon unreachable on ${ENDPOINT}"
snapshot_metrics
grep -q "^# TYPE perf_sentinel_otlp_spans_received_total " "${TMP_DIR}/metrics.txt" \
  || die "0.8.7 span counters absent on the scoped daemon (image=${DAEMON_IMAGE})"
RECEIVED_BEFORE="$(metric_val perf_sentinel_otlp_spans_received_total)"
NOTIO_BEFORE="$(labeled_metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="not_io"}')"
RESTARTS_BEFORE="$(daemon_restarts)"
ok "scoped daemon up with image ${DAEMON_IMAGE}, NDJSON sidecar feeding"

# =============================================================================
step "Concurrent load: gRPC Job + HTTP Job (${TPS} tps x ${LOAD_SECONDS}s each)"
for proto in grpc http-pb; do
  name="tracegen-${proto//-/}"
  prefix="g"; [ "${proto}" = "http-pb" ] && prefix="h"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app: tracegen }
    spec:
      restartPolicy: Never
      containers:
        - name: tracegen
          image: lab-tracegen:1
          imagePullPolicy: Never
          args:
            - "--endpoint=http://multi-source-daemon.${NS}.svc.cluster.local:1431$([ "${proto}" = "grpc" ] && echo 7 || echo 8)"
            - "--protocol=${proto}"
            - "--services=24"
            - "--service-prefix=${prefix}"
            - "--tps=${TPS}"
            - "--duration=${LOAD_SECONDS}"
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits: { cpu: "1", memory: 192Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
EOF
done

# =============================================================================
step "Concurrent batch reader: perf-sentinel tempo against the lab Tempo"
TEMPO_RESULT="skip"
if [ -x "${PERF_SENTINEL_LOCAL_BIN}" ]; then
  kubectl -n observability port-forward svc/tempo "${TEMPO_LOCAL_PORT}:3200" >/dev/null 2>&1 &
  sleep 3
  TEMPO_START="$(date +%s)"
  if timeout 120 "${PERF_SENTINEL_LOCAL_BIN}" tempo --endpoint "http://localhost:${TEMPO_LOCAL_PORT}" \
       --service order-service --lookback 1h --format json > "${TMP_DIR}/tempo.json" 2>"${TMP_DIR}/tempo.err"; then
    TEMPO_WALL=$(( $(date +%s) - TEMPO_START ))
    python3 -c "import json;json.load(open('${TMP_DIR}/tempo.json'))" || die "tempo output not JSON"
    TEMPO_RESULT="pass (${TEMPO_WALL}s)"
    ok "tempo batch read finished in ${TEMPO_WALL}s under load"
  else
    # An empty Tempo (fleet down) is a legitimate state: accept the
    # documented no-traces failure, reject anything else.
    if grep -qiE "no traces|not found|empty" "${TMP_DIR}/tempo.err"; then
      TEMPO_RESULT="skip (tempo empty, fleet down)"
      skip "tempo has no traces (fleet down) - reader path exercised, no data"
    else
      die "tempo subcommand failed under load: $(tail -2 "${TMP_DIR}/tempo.err")"
    fi
  fi
else
  skip "no local binary at ${PERF_SENTINEL_LOCAL_BIN}; tempo reader skipped"
fi

# =============================================================================
step "Wait for the Jobs and assert"
for j in tracegen-grpc tracegen-httppb; do
  kubectl -n "${NS}" wait --for=condition=complete "job/${j}" --timeout=$(( LOAD_SECONDS + 120 ))s >/dev/null 2>&1 \
    || die "${j} did not complete: $(kubectl -n "${NS}" logs "job/${j}" --tail=3 2>/dev/null | tr '\n' ' ')"
done
GRPC_SENT="$(kubectl -n "${NS}" logs job/tracegen-grpc --tail=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["spans_io"])')"
HTTP_SENT="$(kubectl -n "${NS}" logs job/tracegen-httppb --tail=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["spans_io"])')"
GRPC_TOTAL="$(kubectl -n "${NS}" logs job/tracegen-grpc --tail=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["spans"])')"
HTTP_TOTAL="$(kubectl -n "${NS}" logs job/tracegen-httppb --tail=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["spans"])')"
GRPC_TRACES="$(kubectl -n "${NS}" logs job/tracegen-grpc --tail=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["traces"])')"
HTTP_TRACES="$(kubectl -n "${NS}" logs job/tracegen-httppb --tail=1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["traces"])')"

sleep 8
snapshot_metrics || die "scoped daemon /metrics unreachable after load"
RECEIVED_AFTER="$(metric_val perf_sentinel_otlp_spans_received_total)"
NOTIO_AFTER="$(labeled_metric_val 'perf_sentinel_otlp_spans_filtered_total{reason="not_io"}')"
D_RECEIVED=$(( RECEIVED_AFTER - RECEIVED_BEFORE ))
D_NOTIO=$(( NOTIO_AFTER - NOTIO_BEFORE ))
SENT_OTLP=$(( GRPC_TOTAL + HTTP_TOTAL ))
LOW=$(( SENT_OTLP * 90 / 100 )); HIGH=$(( SENT_OTLP * 110 / 100 ))
[ "${D_RECEIVED}" -ge "${LOW}" ] && [ "${D_RECEIVED}" -le "${HIGH}" ] \
  || die "otlp_spans_received delta ${D_RECEIVED} outside ±10% of sent ${SENT_OTLP}"
# One SERVER root per trace, and every one of them is filtered. perf-sentinel
# drops SERVER spans so a hop is not counted twice, and it does that on the kind
# alone: the root carries http.url and is dropped all the same, which is why
# this used to expect a flat counter and got one hit per trace instead.
#
# The equality is the assertion, not a bound: every other span the generator
# emits carries db.system with a statement, or a URL with a method, so anything
# beyond the roots landing here means the generator stopped emitting I/O.
#
# It rests on one generator invariant: every template in tools/tracegen builds
# exactly one parentless root through templates._root. A template that emitted
# two, or none, would turn this red with a message blaming the engine, so change
# that helper and this number together.
SENT_TRACES=$(( GRPC_TRACES + HTTP_TRACES ))
[ "${D_NOTIO}" -eq "${SENT_TRACES}" ] \
  || die "filtered{not_io} moved by ${D_NOTIO}, expected ${SENT_TRACES} (one SERVER root per trace)"

# No starvation: all three live prefixes present in the export report.
curl -fsS "${ENDPOINT}/api/export/report" > "${TMP_DIR}/export.json" || die "export/report unreachable"
for prefix in g- h- n-; do
  grep -q "\"${prefix}" "${TMP_DIR}/export.json" \
    || python3 -c "
import json,sys
r=json.load(open('${TMP_DIR}/export.json'))
blob=json.dumps(r)
sys.exit(0 if '${prefix}' in blob else 1)" \
    || die "no service with prefix ${prefix} in the export report (source starved?)"
done
RESTARTS_AFTER="$(daemon_restarts)"
[ "${RESTARTS_AFTER}" = "${RESTARTS_BEFORE}" ] || die "scoped daemon restarted"
ok "received +${D_RECEIVED} (sent ${SENT_OTLP}), not_io ${D_NOTIO} == one root per trace, three prefixes present, restarts=0"

verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| check | value |"
  echo "|---|---|"
  echo "| image | ${DAEMON_IMAGE} |"
  echo "| gRPC sent (spans/io) | ${GRPC_TOTAL}/${GRPC_SENT} |"
  echo "| HTTP sent (spans/io) | ${HTTP_TOTAL}/${HTTP_SENT} |"
  echo "| otlp received delta | ${D_RECEIVED} (±10% of ${SENT_OTLP}) |"
  echo "| filtered not_io delta | ${D_NOTIO} (one SERVER root per trace, ${SENT_TRACES} sent) |"
  echo "| tempo reader | ${TEMPO_RESULT} |"
  echo "| restarts (daemon container) | ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER} |"
  echo ""
  echo "Feedback item: the NDJSON socket path has no received-spans counter,"
  echo "so its volume is only visible via events_processed_total."
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
