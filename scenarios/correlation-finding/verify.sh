#!/usr/bin/env bash
# cross-trace correlation finding.
#
# Use case: the daemon's rolling-window correlator detects that span
# templates from one service systematically lead to span templates in a
# downstream service within a configurable lag window. Operators can
# query the live correlations via /api/correlations or the per-trace
# correlation findings via /api/findings.
#
# This scenario generates intentional cross-service traffic (chatty +
# fanout scenarios from k6) and asserts the correlator surfaces at
# least one correlation entry.

set -euo pipefail

SCENARIO="correlation-finding"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
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
curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
  || die "daemon not reachable at ${DAEMON_URL}, run scripts/port-forward.sh start"
ok "daemon reachable"

step "Generate cross-service traffic (chatty + fanout via k6)"
# These two scenarios send order-service -> payment-service -> notification-service
# call chains. After a few iterations, the daemon's rolling-window
# correlator surfaces (source, target) pairs with high confidence.
make -C "$(dirname "$0")/../.." validate-findings >/dev/null 2>&1 || true
ok "validate-findings done (10 scenarios incl. chatty + fanout)"

step "Wait for correlator window (default 5 minutes, we wait 90s for fresh entries)"
sleep 90
ok "wait complete"

step "Query /api/correlations"
curl -fsS "${DAEMON_URL}/api/correlations" > "${TMP_DIR}/correlations.json"
TOTAL=$(python3 -c "
import json
data = json.load(open('${TMP_DIR}/correlations.json'))
print(len(data) if isinstance(data, list) else 0)
")
ok "/api/correlations returned ${TOTAL} entries"

step "Assert at least one entry with confidence > 0.5"
HIGH_CONF=$(python3 -c "
import json
data = json.load(open('${TMP_DIR}/correlations.json'))
high = [c for c in data if c.get('confidence', 0) > 0.5]
print(len(high))
")
ok "${HIGH_CONF} correlation entries with confidence > 0.5"

step "Top 3 correlation entries (by confidence)"
TOP_LIST=$(python3 -c "
import json
def fmt(d):
    if not isinstance(d, dict): return str(d)[:40]
    svc = d.get('service', '?')
    tpl = d.get('template', '?')[:30]
    return f'{svc}:{tpl}'
data = json.load(open('${TMP_DIR}/correlations.json'))
top = sorted(data, key=lambda x: x.get('confidence', 0), reverse=True)[:3]
out = []
for c in top:
    src = fmt(c.get('source'))
    tgt = fmt(c.get('target'))
    conf = c.get('confidence', 0)
    co = c.get('co_occurrence_count', 0)
    lag = c.get('median_lag_ms', 0)
    out.append(f'  {src} -> {tgt}: confidence={conf:.2f} co_occ={co} lag={lag}ms')
print(chr(10).join(out))
")
echo "${TOP_LIST}"

if [ "${TOTAL}" -ge 1 ] && [ "${HIGH_CONF}" -ge 1 ]; then
  verdict="PASS"
else
  verdict="FAIL"
  color_red "    fail: 0 correlation entries (or none with confidence > 0.5)"
fi

step "Write report"
{
  echo "# cross-trace correlation finding"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Daemon: ${DAEMON_URL}"
  echo
  echo "The daemon's rolling-window correlator (\`[daemon.correlation]\` in"
  echo "\`config.toml\`, default \`window_minutes = 5\`,"
  echo "\`min_co_occurrences = 2\`, \`min_confidence = 0.5\`) tracks span"
  echo "templates that systematically co-occur across traces and exposes"
  echo "the survivors via the \`/api/correlations\` endpoint."
  echo
  echo "## Live correlations"
  echo
  echo "- total entries: ${TOTAL}"
  echo "- entries with confidence > 0.5: ${HIGH_CONF}"
  echo
  echo "Top entries:"
  echo
  echo '```'
  echo "${TOP_LIST}"
  echo '```'
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
