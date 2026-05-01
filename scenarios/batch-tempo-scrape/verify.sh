#!/usr/bin/env bash
# batch over Tempo storage.
#
# Use case: a user has Tempo deployed in their cluster but no perf-sentinel
# daemon running 24/7. They run a periodic batch CI job that fetches
# recent traces from Tempo and runs perf-sentinel detection on them.
#
# Tests `perf-sentinel tempo --endpoint ...` end to end. The CLI
# subcommand fetches traces via Tempo's `/api/search` and `/api/traces/<id>`
# endpoints, parses the OTLP-JSON response, and runs the same detection
# pipeline as `analyze`. Findings are emitted to stdout.

set -euo pipefail

SCENARIO="batch-tempo-scrape"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
IMAGE="ghcr.io/robintra/perf-sentinel:0.5.16"
# Use host.docker.internal so this works on both Docker Desktop (Mac/Win)
# and Linux runners (with --add-host host.docker.internal:host-gateway).
HOST_FROM_CONTAINER="host.docker.internal"
TEMPO_URL_HOST="${TEMPO_URL_HOST:-http://localhost:3200}"
TEMPO_URL_IN_CONTAINER="http://${HOST_FROM_CONTAINER}:3200"
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

step "Probe Tempo from host"
ready=0
for i in $(seq 1 30); do
  if curl -fsS "${TEMPO_URL_HOST}/ready" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "${ready}" != "1" ]; then
  die "Tempo not reachable at ${TEMPO_URL_HOST} after 60s, run scripts/port-forward.sh start"
fi
ok "Tempo ready"

step "Run perf-sentinel tempo --endpoint <url> --service order-service"
# host.docker.internal resolves to the host both on Docker Desktop and
# on Linux runners with --add-host host.docker.internal:host-gateway.
# This avoids the --network host caveat (Docker Desktop VM does not give
# the container the host network on Mac/Windows).
if docker run --rm \
     --add-host "${HOST_FROM_CONTAINER}:host-gateway" \
     "${IMAGE}" \
     tempo \
       --endpoint "${TEMPO_URL_IN_CONTAINER}" \
       --service order-service \
       --lookback 1h \
       --max-traces 50 \
       --format json \
     > "${TMP_DIR}/tempo-findings.json" \
     2> "${TMP_DIR}/tempo.log"; then
  ok "tempo subcommand exited 0"
else
  cat "${TMP_DIR}/tempo.log" | tail -10
  verdict="FAIL"
fi

if [ "${verdict}" != "FAIL" ]; then
  step "Inspect findings JSON"
  if [ ! -s "${TMP_DIR}/tempo-findings.json" ]; then
    color_red "    fail: tempo-findings.json empty"
    verdict="FAIL"
  elif ! python3 -c "
import json, sys
data = json.load(open('${TMP_DIR}/tempo-findings.json'))
findings = data.get('findings', [])
print(f'findings: {len(findings)}')
print(f'analysis: events_processed={data.get(\"analysis\", {}).get(\"events_processed\")}, traces_analyzed={data.get(\"analysis\", {}).get(\"traces_analyzed\")}')
" > "${TMP_DIR}/parse.log" 2>&1; then
    color_red "    fail: tempo-findings.json not parseable"
    cat "${TMP_DIR}/parse.log"
    verdict="FAIL"
  else
    cat "${TMP_DIR}/parse.log"
    findings_count=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/tempo-findings.json')).get('findings', [])))")
    traces_analyzed=$(python3 -c "import json; print(json.load(open('${TMP_DIR}/tempo-findings.json')).get('analysis', {}).get('traces_analyzed', 0))")
    if [ "${traces_analyzed}" -gt 0 ]; then
      verdict="PASS"
      ok "${findings_count} findings from ${traces_analyzed} Tempo traces"
    else
      verdict="FAIL"
      color_red "    fail: 0 traces analyzed (Tempo subcommand could not fetch or parse)"
    fi
  fi
fi

step "Write report"
{
  echo "# batch over Tempo storage"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Image: ${IMAGE}"
  echo "Tempo: ${TEMPO_URL_HOST} (in-container: ${TEMPO_URL_IN_CONTAINER})"
  echo
  echo "Command:"
  echo
  echo '```bash'
  echo "perf-sentinel tempo \\"
  echo "  --endpoint ${TEMPO_URL_IN_CONTAINER} \\"
  echo "  --service order-service \\"
  echo "  --lookback 1h --max-traces 50 \\"
  echo "  --format json"
  echo '```'
  echo
  echo "## Output"
  echo
  if [ -s "${TMP_DIR}/tempo-findings.json" ]; then
    echo "Findings: ${findings_count}"
    echo
    echo '```json'
    head -c 500 "${TMP_DIR}/tempo-findings.json"
    echo
    echo "..."
    echo '```'
  else
    echo "(no output)"
  fi
  echo
  echo "## Logs"
  echo
  echo '```'
  tail -20 "${TMP_DIR}/tempo.log" 2>/dev/null || true
  echo '```'
  echo
  echo "## Followup item 5 verdict"
  echo
  if [ "${verdict}" = "PASS" ]; then
    echo "RESOLVED. The \`tempo\` subcommand fetches traces from Tempo's"
    echo "OTLP-JSON-only API and runs detection end to end without external"
    echo "conversion. Item 5 of \`project_perf_sentinel_followup.md\` can be"
    echo "marked as RESOLVED in 0.5.16+."
  else
    echo "OPEN. The \`tempo\` subcommand failed in this run, see the logs"
    echo "above. Item 5 stays OPEN until further diagnostic."
  fi
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
