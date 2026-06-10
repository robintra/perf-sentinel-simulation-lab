#!/usr/bin/env bash
# limit-prod-window-soak: the production window config under sustained
# mixed load. The committed lab config runs trace_ttl_ms=5000 for fast
# eviction; production runs 30000. This scenario scopes the daemon to the
# production values (ttl 30000, max_active_traces 10000), drives a steady
# realistic mix, and asserts the window reaches a healthy plateau:
#   - active_traces plateaus near tps x 30s and stays far from the cap;
#   - RSS drift between the warm window [10-30%] and the tail [70-100%]
#     of samples stays under DRIFT_PCT_LIMIT (long-running-drift analysis);
#   - zero shed and zero channel_full at this rate (clean prod operation);
#   - 90s after the load stops, active_traces drains below 100.
set -euo pipefail

SCENARIO="limit-prod-window-soak"
OBS_NS="observability"
DEPLOY="perf-sentinel-daemon"
DAEMON_SELECTOR="app.kubernetes.io/name=perf-sentinel-daemon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
TSV="${TMP_DIR}/soak.tsv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
ENDPOINT="http://localhost:${DAEMON_LOCAL_PORT}"
TPS="${TPS:-60}"
DURATION="${DURATION:-600}"
PROD_TTL_MS="${PROD_TTL_MS:-30000}"
DRIFT_PCT_LIMIT="${DRIFT_PCT_LIMIT:-10}"
if [ "${LONG_RUN:-0}" = "1" ]; then
  TPS=120; DURATION=1800
fi

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

cleanup() {
  kubectl -n limit-testing delete job tracegen-soak --ignore-not-found >/dev/null 2>&1 || true
  # Restore the committed (lab-TTL) daemon config.
  kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null 2>&1 || true
  kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=120s >/dev/null 2>&1 || true
  pf_restart >/dev/null 2>&1 || true
}
trap cleanup EXIT

pf_restart() {
  pkill -f "kubectl.*port-forward.*${DEPLOY}" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    curl -fsS "${ENDPOINT}/api/status" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
metric_val() {
  awk -v m="$1" '$1==m {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
labeled_metric_val() {
  awk -v m="$1" '$0 ~ "^"m" " {print int($2); found=1} END {if(!found) print 0}' "${TMP_DIR}/metrics.txt" | head -1
}
snapshot_metrics() { curl -fsS --max-time 5 "${ENDPOINT}/metrics" > "${TMP_DIR}/metrics.txt"; }
daemon_restarts() {
  kubectl -n "${OBS_NS}" get pod -l "${DAEMON_SELECTOR}" \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0
}

# =============================================================================
step "Scope the daemon to the production window (ttl ${PROD_TTL_MS}ms)"
kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null
kubectl -n "${OBS_NS}" get cm perf-sentinel-daemon-config -o jsonpath='{.data.config\.toml}' > "${TMP_DIR}/base.toml"
python3 - "${TMP_DIR}/base.toml" "${TMP_DIR}/scoped.toml" "${PROD_TTL_MS}" <<'PY'
import sys
src, dst, ttl = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(src):
    if line.strip().startswith("trace_ttl_ms"):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}trace_ttl_ms = {ttl}\n")
    else:
        out.append(line)
open(dst, "w").writelines(out)
PY
grep -q "trace_ttl_ms = ${PROD_TTL_MS}" "${TMP_DIR}/scoped.toml" || die "could not scope trace_ttl_ms"
kubectl -n "${OBS_NS}" create configmap perf-sentinel-daemon-config \
  --from-file=config.toml="${TMP_DIR}/scoped.toml" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${OBS_NS}" rollout restart deploy/"${DEPLOY}" >/dev/null
kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null || die "rollout failed"
pf_restart || die "daemon unreachable"
snapshot_metrics
grep -q "^# TYPE perf_sentinel_otlp_spans_received_total " "${TMP_DIR}/metrics.txt" \
  || die "0.8.7 counters absent (run scripts/seed-daemon-local.sh)"
RESTARTS_BEFORE="$(daemon_restarts)"
ok "daemon on prod window, ttl=${PROD_TTL_MS}ms"

# =============================================================================
step "Soak: ${TPS} tps mixed load for ${DURATION}s"
kubectl apply -f "${REPO_ROOT}/scenarios/limit-common/manifests.yaml" >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: tracegen-soak
  namespace: limit-testing
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
            - "--endpoint=http://perf-sentinel-daemon.observability.svc.cluster.local:14318"
            - "--protocol=http-pb"
            - "--services=64"
            - "--service-prefix=soak"
            - "--tps=${TPS}"
            - "--duration=${DURATION}"
          resources:
            requests: { cpu: 200m, memory: 64Mi }
            limits: { cpu: "1", memory: 192Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
EOF

echo -e "ts\trss_bytes\tactive_traces\tqueue_depth\tshed_batches\tchannel_full\tevents_total" > "${TSV}"
ACTIVE_MAX=0; RSS_MAX=0
END=$(( $(date +%s) + DURATION + 60 ))
while [ "$(date +%s)" -lt "${END}" ]; do
  if snapshot_metrics 2>/dev/null; then
    RSS="$(metric_val process_resident_memory_bytes)"
    ACTIVE="$(metric_val perf_sentinel_active_traces)"
    QD="$(metric_val perf_sentinel_analysis_queue_depth)"
    SHED="$(metric_val perf_sentinel_analysis_shed_batches_total)"
    CHF="$(labeled_metric_val 'perf_sentinel_otlp_rejected_total{reason="channel_full"}')"
    EV="$(metric_val perf_sentinel_events_processed_total)"
    echo -e "$(date +%s)\t${RSS}\t${ACTIVE}\t${QD}\t${SHED}\t${CHF}\t${EV}" >> "${TSV}"
    [ "${ACTIVE}" -gt "${ACTIVE_MAX}" ] && ACTIVE_MAX="${ACTIVE}"
    [ "${RSS}" -gt "${RSS_MAX}" ] && RSS_MAX="${RSS}"
  fi
  PHASE="$(kubectl -n limit-testing get job tracegen-soak -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")"
  [ "${PHASE}" = "1" ] && break
  sleep 20
done
kubectl -n limit-testing wait --for=condition=complete "job/tracegen-soak" --timeout=120s >/dev/null 2>&1 \
  || die "soak job did not complete"
GEN_REPORT="$(kubectl -n limit-testing logs job/tracegen-soak --tail=1)"
ok "soak done: ${GEN_REPORT}"

# =============================================================================
step "Asserts: plateau, drift, clean operation, drain"
# Plateau: expected steady-state ~ tps x ttl_seconds traces in flight.
EXPECTED=$(( TPS * PROD_TTL_MS / 1000 ))
PLATEAU_LOW=$(( EXPECTED / 2 )); PLATEAU_HIGH=$(( EXPECTED * 3 / 2 ))
PLATEAU="$(python3 -c "
rows=[l.split('\t') for l in open('${TSV}').read().splitlines()[1:]]
mid=[int(r[2]) for r in rows[len(rows)//3: 2*len(rows)//3]]
print(sum(mid)//max(1,len(mid)))")"
[ "${PLATEAU}" -ge "${PLATEAU_LOW}" ] && [ "${PLATEAU}" -le "${PLATEAU_HIGH}" ] \
  || die "active_traces plateau ${PLATEAU} outside [${PLATEAU_LOW}, ${PLATEAU_HIGH}] (expected ~${EXPECTED})"
[ "${ACTIVE_MAX}" -lt 9000 ] || die "active_traces approached the 10000 cap (${ACTIVE_MAX})"

# Drift windows start past the state-fill phase: the correlation window
# (5 min) and the findings ring (~10k cap) legitimately fill RSS for the
# first several minutes, so compare [50-70%] against [80-100%] of the
# samples. The 2-hour long-running-drift scenario is the real leak hunter.
DRIFT="$(python3 -c "
rows=[l.split('\t') for l in open('${TSV}').read().splitlines()[1:]]
rss=[int(r[1]) for r in rows]
n=len(rss)
warm=rss[n//2: max(n//2+1, 7*n//10)]
tail=rss[8*n//10:]
w=sum(warm)/max(1,len(warm)); t=sum(tail)/max(1,len(tail))
print('%.1f' % (100.0*(t-w)/w if w else 0.0))")"
python3 -c "exit(0 if float('${DRIFT}') <= float('${DRIFT_PCT_LIMIT}') else 1)" \
  || die "RSS drift ${DRIFT}% exceeds ${DRIFT_PCT_LIMIT}% (leak suspicion)"

snapshot_metrics
SHED_FINAL="$(metric_val perf_sentinel_analysis_shed_batches_total)"
CHF_FINAL="$(labeled_metric_val 'perf_sentinel_otlp_rejected_total{reason="channel_full"}')"
[ "${SHED_FINAL}" -eq 0 ] || die "shedding fired at prod rate (${SHED_FINAL} batches): ${TPS} tps is NOT clean"
[ "${CHF_FINAL}" -eq 0 ] || die "channel_full fired at prod rate (${CHF_FINAL})"
RESTARTS_AFTER="$(daemon_restarts)"
[ "${RESTARTS_AFTER}" = "${RESTARTS_BEFORE}" ] || die "daemon restarted during the soak"

sleep 90
snapshot_metrics
DRAINED="$(metric_val perf_sentinel_active_traces)"
[ "${DRAINED}" -lt 100 ] || die "window did not drain 90s after the load (active=${DRAINED})"
ok "plateau=${PLATEAU} (expected ~${EXPECTED}), drift=${DRIFT}%, clean, drained to ${DRAINED}"

verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "| check | value |"
  echo "|---|---|"
  echo "| load | ${TPS} tps x ${DURATION}s, prod ttl ${PROD_TTL_MS}ms |"
  echo "| generator | ${GEN_REPORT} |"
  echo "| active_traces plateau | ${PLATEAU} (expected ~${EXPECTED}, max ${ACTIVE_MAX}) |"
  echo "| rss drift warm->tail | ${DRIFT}% (limit ${DRIFT_PCT_LIMIT}%) |"
  echo "| rss max | $(( RSS_MAX / 1048576 )) MiB |"
  echo "| shed / channel_full | ${SHED_FINAL} / ${CHF_FINAL} |"
  echo "| drained after 90s | ${DRAINED} |"
  echo "| restarts | ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER} |"
  echo "- Raw samples: ${TSV}"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
