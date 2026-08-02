#!/usr/bin/env bash
# perf-sentinel report --pg-stat live integration.
#
# Use case: a CI dashboard pairs perf-sentinel trace findings with
# `pg_stat_statements` data to surface SQL hotspots beside anti-pattern
# detections. Operators get a single HTML dashboard with a `pg_stat`
# tab showing the top normalized templates by exec time / calls /
# shared_blks, plus an Explain → pg_stat cross-navigation that maps
# detected anti-patterns onto the matching template rows.

set -euo pipefail

SCENARIO="pg-stat"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
# The image under validation, resolved by scripts/resolve-image.sh:
# PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then the daemon manifest pin.
# It used to default to a hardcoded old tag, which meant the gate could report a
# PASS for a version this scenario had never executed.
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"
TMP_DIR="/tmp/${SCENARIO}"
TRACES_FIXTURE="$(cd "$(dirname "$0")/../.." && pwd)/artifacts/fixtures/em-real-time-traces.json"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

step "Verify pg_stat_statements extension is loaded"
EXT_OK=$(kubectl -n db exec sts/postgres -- psql -U lab -d lab -tAc \
  "SELECT extname FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null \
  | tr -d ' \r\n')
if [ "${EXT_OK}" != "pg_stat_statements" ]; then
  die "pg_stat_statements extension not installed on the lab Postgres (run kubectl exec sts/postgres psql -c \"CREATE EXTENSION pg_stat_statements;\" first)"
fi
ok "pg_stat_statements extension loaded"

step "Reset pg_stat_statements counters"
kubectl -n db exec sts/postgres -- psql -U lab -d lab -c "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 || true
ok "counters reset"

step "Generate workload (validate-findings drives 1500+ SQL queries)"
VF_LOG="${TMP_DIR}/validate-findings.log"
if ! make -C "$(dirname "$0")/../.." validate-findings > "${VF_LOG}" 2>&1; then
  tail -20 "${VF_LOG}" >&2 || true
  die "validate-findings failed, see ${VF_LOG}"
fi
ok "workload done (log: ${VF_LOG})"

step "Wait for stat collector to flush"
sleep 15

step "Dump pg_stat_statements via psql COPY"
# Flatten newlines/tabs/CRs in the `query` column so each pg_stat row
# stays on a single CSV line. Without this, multi-line SQL queries
# break the perf-sentinel CSV parser at line N where N is the first
# query continuation line (it sees an empty `calls` column).
kubectl -n db exec sts/postgres -- psql -U lab -d lab -c "\copy (SELECT queryid, regexp_replace(query, E'[\r\n\t]+', ' ', 'g') AS query, calls, total_exec_time, mean_exec_time, rows, shared_blks_hit, shared_blks_read FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 100) TO STDOUT WITH CSV HEADER;" \
  > "${TMP_DIR}/pg-stat.csv" 2>/dev/null
ROW_COUNT=$(($(wc -l < "${TMP_DIR}/pg-stat.csv") - 1))
ok "exported ${ROW_COUNT} pg_stat_statements rows to CSV"
if [ "${ROW_COUNT}" -lt 5 ]; then
  die "expected at least 5 SQL templates after validate-findings, got ${ROW_COUNT}"
fi

step "Run perf-sentinel report --input <traces> --pg-stat <csv>"
if docker run --rm -u "$(id -u):$(id -g)" \
     -v "${TRACES_FIXTURE}:/input/traces.json:ro" \
     -v "${TMP_DIR}/pg-stat.csv:/input/pg-stat.csv:ro" \
     -v "${TMP_DIR}:/output" \
     "${IMAGE}" \
     report \
       --input /input/traces.json \
       --pg-stat /input/pg-stat.csv \
       --output /output/dashboard.html \
     > "${TMP_DIR}/report.log" 2>&1; then
  ok "report subcommand exited 0"
else
  cat "${TMP_DIR}/report.log" | tail -10
  verdict="FAIL"
fi

if [ "${verdict}" != "FAIL" ]; then
  step "Inspect HTML for pg_stat tab"
  HTML_BYTES=$(wc -c < "${TMP_DIR}/dashboard.html")
  if [ "${HTML_BYTES}" -lt 10000 ]; then
    verdict="FAIL"
    color_red "    fail: dashboard.html suspiciously small (${HTML_BYTES} bytes)"
  elif ! grep -qE '"pg_stat"|pg-stat|pg_stat-tab|pgStat' "${TMP_DIR}/dashboard.html"; then
    verdict="FAIL"
    color_red "    fail: HTML does not mention pg_stat tab"
    grep -oE 'tab[a-z_-]*' "${TMP_DIR}/dashboard.html" | sort -u | head -5
  else
    verdict="PASS"
    PG_REFS=$(grep -oE '(pg_stat|pg-stat|pgStat)[a-z_-]*' "${TMP_DIR}/dashboard.html" | sort -u | wc -l | tr -d ' ')
    ok "dashboard contains ${PG_REFS} distinct pg_stat references (HTML ${HTML_BYTES} bytes)"
  fi
fi

# Path 2: pg_stat via Prometheus scraping postgres-exporter. Skipped
# unless postgres-exporter is deployed (via make verify-grafana-dashboard).
PROM_PATH_VERDICT="SKIPPED"
if kubectl -n db get deploy postgres-exporter >/dev/null 2>&1; then
  step "Path 2: --pg-stat-prometheus (Prometheus scraping postgres-exporter)"
  kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 \
    > "${TMP_DIR}/prom-pf.log" 2>&1 &
  PIDS+=($!)
  sleep 3
  # On macOS Docker Desktop, --network host does NOT bridge to the
  # macOS host (docker engine runs in a Linux VM). Use
  # host.docker.internal:host-gateway which resolves to the host
  # gateway from the VM. On Linux Docker, host networking works
  # directly with localhost.
  if [ "$(uname -s)" = "Linux" ]; then
    PROM_URL_FROM_DOCKER="http://localhost:9090"
    DOCKER_NET_FLAGS=(--network host)
  else
    PROM_URL_FROM_DOCKER="http://host.docker.internal:9090"
    DOCKER_NET_FLAGS=(--add-host=host.docker.internal:host-gateway)
  fi
  if docker run --rm -u "$(id -u):$(id -g)" \
       "${DOCKER_NET_FLAGS[@]}" \
       -v "${TRACES_FIXTURE}:/input/traces.json:ro" \
       -v "${TMP_DIR}:/output" \
       "${IMAGE}" \
       report \
         --input /input/traces.json \
         --pg-stat-prometheus "${PROM_URL_FROM_DOCKER}" \
         --output /output/dashboard-prometheus.html \
       > "${TMP_DIR}/report-prom.log" 2>&1; then
    if [ -s "${TMP_DIR}/dashboard-prometheus.html" ] \
       && grep -qE '"pg_stat"|pg-stat|pg_stat-tab|pgStat' "${TMP_DIR}/dashboard-prometheus.html"; then
      PROM_PATH_VERDICT="PASS"
      PROM_BYTES=$(wc -c < "${TMP_DIR}/dashboard-prometheus.html")
      ok "Path 2 PASS: pg_stat dashboard rendered via Prometheus path (${PROM_BYTES} bytes)"
    else
      PROM_PATH_VERDICT="FAIL"
      color_red "    fail: Prometheus path produced empty or pg_stat-less dashboard"
      tail -10 "${TMP_DIR}/report-prom.log" || true
    fi
  else
    PROM_PATH_VERDICT="FAIL"
    color_red "    fail: report --pg-stat-prometheus exited non-zero, see ${TMP_DIR}/report-prom.log"
    tail -10 "${TMP_DIR}/report-prom.log" || true
  fi
  # Port-forward will be killed by the cleanup trap on EXIT.
else
  step "Path 2: --pg-stat-prometheus"
  ok "SKIP: postgres-exporter not deployed (run make verify-grafana-dashboard first to unlock Path 2)"
fi

step "Write report"
{
  echo "# perf-sentinel report --pg-stat live integration"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Image: ${IMAGE}"
  echo
  echo "## Setup"
  echo
  echo "- Lab Postgres has \`pg_stat_statements\` enabled via"
  echo "  \`shared_preload_libraries=pg_stat_statements\` (manifests/postgres.yaml)"
  echo "  plus \`CREATE EXTENSION pg_stat_statements\` (manifests/postgres-init-schemas.yaml)."
  echo "- Workload: \`make validate-findings\` (1500+ SQL queries across the 10 anti-pattern scenarios)."
  echo "- Export: \`psql \\copy (SELECT ... FROM pg_stat_statements) TO STDOUT WITH CSV HEADER\`."
  echo
  echo "## Output"
  echo
  echo "- pg_stat_statements rows exported: ${ROW_COUNT}"
  echo "- Dashboard HTML (Path 1, CSV): \`${TMP_DIR}/dashboard.html\` ($(wc -c < "${TMP_DIR}/dashboard.html" 2>/dev/null || echo 0) bytes)"
  echo "- Dashboard HTML (Path 2, Prometheus): \`${TMP_DIR}/dashboard-prometheus.html\` ($(wc -c < "${TMP_DIR}/dashboard-prometheus.html" 2>/dev/null || echo 0) bytes)"
  echo
  echo "## Top SQL templates by total exec time"
  echo
  echo '```'
  head -6 "${TMP_DIR}/pg-stat.csv" 2>/dev/null || true
  echo '```'
  echo
  echo "## Verdicts"
  echo
  echo "- Path 1 (CSV via psql copy): ${verdict}"
  echo "- Path 2 (Prometheus via postgres-exporter): ${PROM_PATH_VERDICT}"
} > "${REPORT}"

# Final verdict considers both paths. Path 2 SKIPPED is acceptable
# (postgres-exporter is optional, only deployed by verify-grafana-dashboard).
if [ "${verdict}" = "PASS" ] && [ "${PROM_PATH_VERDICT}" != "FAIL" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "Path 1=${verdict}, Path 2=${PROM_PATH_VERDICT}, see ${REPORT}"
fi
