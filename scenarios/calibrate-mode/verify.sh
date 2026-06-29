#!/usr/bin/env bash
# calibrate mode: energy coefficients calibration.
#
# Use case: a customer wants accurate green-ops scoring on their own
# hardware. They measure power consumption during a baseline trace
# window and feed both the trace JSON and the power CSV to
# `perf-sentinel calibrate`. The output is a calibration TOML with
# coefficients tuned to their hardware.
#
# Note: `calibrate` is NOT for anti-pattern thresholds (the brief was
# wrong on that). It is for energy coefficients (cf. `calibrate --help`:
# "Calibrate energy coefficients from real measurements").

set -euo pipefail

SCENARIO="calibrate-mode"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
IMAGE="ghcr.io/robintra/perf-sentinel:0.5.21"
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

step "Verify trace fixture is present"
if [ ! -s "${TRACES_FIXTURE}" ]; then
  die "missing trace fixture ${TRACES_FIXTURE}, run scripts/capture-trace-fixture.sh first"
fi
ok "trace fixture present ($(wc -c < "${TRACES_FIXTURE}") bytes)"

step "Generate synthetic power_watts CSV that overlaps the trace window"
# Format expected by `calibrate --measured-energy` (discovered via probe):
# `timestamp,service,power_watts` with ISO-8601 UTC timestamps. The CSV
# must overlap the trace start times, otherwise calibrate skips with
# "no I/O ops found for service in the observation window".
python3 > "${TMP_DIR}/power.csv" << EOF
import json
from datetime import datetime, timezone, timedelta

with open('${TRACES_FIXTURE}') as f:
    data = json.load(f)
starts = [s.get('startTime', 0) for trace in data.get('data', []) for s in trace.get('spans', [])]
if not starts:
    raise SystemExit("no spans in fixture")
min_us, max_us = min(starts), max(starts)
window_seconds = max(60, (max_us - min_us) // 1_000_000 + 1)
start_dt = datetime.fromtimestamp(min_us / 1_000_000, tz=timezone.utc)
print("timestamp,service,power_watts")
services_with_load = [
    ("order-service", 18.0),
    ("payment-service", 14.0),
    ("notification-service", 11.0),
]
for offset in range(0, window_seconds, 30):
    ts = (start_dt + timedelta(seconds=offset)).strftime('%Y-%m-%dT%H:%M:%SZ')
    for svc, watts in services_with_load:
        print(f"{ts},{svc},{watts}")
EOF
ok "synthetic CSV: $(wc -l < "${TMP_DIR}/power.csv") lines covering trace window"

step "Run perf-sentinel calibrate"
if docker run --rm -u "$(id -u):$(id -g)" \
     -v "${TRACES_FIXTURE}:/input/traces.json:ro" \
     -v "${TMP_DIR}/power.csv:/input/power.csv:ro" \
     -v "${TMP_DIR}:/output" \
     "${IMAGE}" \
     calibrate \
       --traces /input/traces.json \
       --measured-energy /input/power.csv \
       --output /output/calibration.toml \
     > "${TMP_DIR}/calibrate.log" 2>&1; then
  ok "calibrate exited 0"
else
  cat "${TMP_DIR}/calibrate.log" | tail -10
  verdict="FAIL"
fi

if [ "${verdict}" != "FAIL" ]; then
  step "Inspect calibration TOML"
  if [ ! -s "${TMP_DIR}/calibration.toml" ]; then
    color_red "    fail: calibration.toml not produced"
    verdict="FAIL"
  elif ! grep -q "^\[calibration\]" "${TMP_DIR}/calibration.toml"; then
    color_red "    fail: calibration.toml missing [calibration] section header"
    verdict="FAIL"
  elif ! grep -q "^\[calibration.services\]" "${TMP_DIR}/calibration.toml"; then
    color_red "    fail: calibration.toml missing [calibration.services] section header"
    verdict="FAIL"
  else
    SERVICES_CALIBRATED=$(grep -cE '^"[a-z-]+-service" =' "${TMP_DIR}/calibration.toml" || echo 0)
    if [ "${SERVICES_CALIBRATED}" -ge 1 ]; then
      verdict="PASS"
      ok "calibration TOML well-formed, ${SERVICES_CALIBRATED} services calibrated"
    else
      verdict="FAIL"
      color_red "    fail: no service entries in calibration.toml"
    fi
  fi
fi

step "Write report"
{
  echo "# calibrate mode (energy coefficients)"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Image: ${IMAGE}"
  echo "Trace fixture: ${TRACES_FIXTURE} ($(wc -c < "${TRACES_FIXTURE}" 2>/dev/null || echo 0) bytes, Jaeger format)"
  echo "Power CSV: ${TMP_DIR}/power.csv (60 seconds at 12.0 W constant)"
  echo
  echo "Command:"
  echo
  echo '```bash'
  echo "perf-sentinel calibrate \\"
  echo "  --traces traces.json \\"
  echo "  --measured-energy power.csv \\"
  echo "  --output calibration.toml"
  echo '```'
  echo
  echo "## Output"
  echo
  if [ -s "${TMP_DIR}/calibration.toml" ]; then
    echo '```toml'
    cat "${TMP_DIR}/calibration.toml"
    echo '```'
  else
    echo "(no output file produced)"
  fi
  echo
  echo "## Logs"
  echo
  echo '```'
  tail -20 "${TMP_DIR}/calibrate.log" 2>/dev/null || true
  echo '```'
  echo
  echo "**Verdict: ${verdict}**"
  echo
  echo "Note: \`calibrate\` produces energy coefficients from power"
  echo "measurements, not anti-pattern thresholds. The brief description"
  echo "of was incorrect on this point."
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
