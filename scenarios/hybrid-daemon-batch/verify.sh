#!/usr/bin/env bash
# hybrid daemon -> batch enriched ingest.
#
# Use case: a developer or CI job has the daemon running in prod and
# wants to render its accumulated Report as a self-contained HTML
# dashboard for post-mortem exploration or shareable artifact upload.
#
# CLI reality check: only one realistic path exists.
#   - `analyze --input` does NOT accept a Report JSON, only raw trace
#     events. Cross-trace correlations are computed daemon-side and are
#     unavailable in batch analyze (cf. `analyze --help`).
#   - The daemon does not expose `/api/export/traces`. Trace re-ingest
#     for SARIF is the use case of (batch over a Tempo backend).
#   - `report --input` accepts a pre-computed daemon Report JSON without
#     re-running detection (cf. `report --help`). This is the post-mortem
#     dashboard path validates.

set -euo pipefail

SCENARIO="hybrid-daemon-batch"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
IMAGE="ghcr.io/robintra/perf-sentinel:0.5.18"
TMP_DIR="/tmp/${SCENARIO}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

step "Probe daemon"
if ! curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1; then
  die "daemon not reachable at ${DAEMON_URL}, run make up-cni first"
fi
ok "daemon reachable"

step "Snapshot the daemon Report JSON"
curl -fsS "${DAEMON_URL}/api/export/report" > "${TMP_DIR}/daemon-report.json"
DAEMON_FINDINGS=$(python3 -c "import json; print(len(json.load(open('${TMP_DIR}/daemon-report.json')).get('findings', [])))")
DAEMON_CORRELATIONS=$(python3 -c "import json; data=json.load(open('${TMP_DIR}/daemon-report.json')); c=data.get('correlations'); print(len(c) if isinstance(c, list) else (1 if c else 0))" 2>/dev/null || echo "?")
ok "daemon report snapshot: ${DAEMON_FINDINGS} findings, ${DAEMON_CORRELATIONS} correlations entries"

step "Render the daemon Report as a self-contained HTML dashboard via report --input"
if docker run --rm \
     -v "${TMP_DIR}/daemon-report.json:/input.json:ro" \
     -v "${TMP_DIR}:/output" \
     "${IMAGE}" \
     report --input /input.json --output /output/dashboard.html \
     > "${TMP_DIR}/report.log" 2>&1; then
  if [ -s "${TMP_DIR}/dashboard.html" ] && head -c 200 "${TMP_DIR}/dashboard.html" | grep -q "<html\|<!DOCTYPE"; then
    HTML_BYTES=$(wc -c < "${TMP_DIR}/dashboard.html")
    if [ "${HTML_BYTES}" -ge 10000 ]; then
      verdict="PASS"
      ok "HTML rendered (${HTML_BYTES} bytes)"
    else
      verdict="FAIL"
      color_red "    fail: HTML output suspiciously small (${HTML_BYTES} bytes)"
    fi
  else
    verdict="FAIL"
    color_red "    fail: HTML output empty or not HTML"
  fi
else
  verdict="FAIL"
  color_red "    fail: report subcommand exited non-zero (see ${TMP_DIR}/report.log)"
fi

step "Write report"
{
  echo "# hybrid daemon -> batch enriched ingest"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Daemon: ${DAEMON_URL} (image ${IMAGE})"
  echo "Daemon findings at snapshot: ${DAEMON_FINDINGS}"
  echo "Daemon correlations entries at snapshot: ${DAEMON_CORRELATIONS}"
  echo
  echo "Path validated: \`perf-sentinel report --input <daemon-report.json> --output <dashboard.html>\`"
  echo
  echo "The CLI does not support \`analyze --format sarif\` on a daemon Report."
  echo "\`analyze\` expects a trace JSON, not a pre-computed Report. The"
  echo "SARIF-from-batch path is covered by the batch-tempo-scrape scenario."
  echo
  echo "## Output"
  echo
  echo "- HTML dashboard: \`${TMP_DIR}/dashboard.html\` ($(wc -c < "${TMP_DIR}/dashboard.html" 2>/dev/null || echo 0) bytes)"
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "FAIL, see ${REPORT}"
fi
