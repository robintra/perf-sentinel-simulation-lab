#!/usr/bin/env bash
# query monitor data plane: the read-only daemon endpoints that back the
# `perf-sentinel query monitor` operator TUI (0.8.8).
#
# The TUI itself is a client-side terminal app and is not driven headless
# here. What this scenario validates is the daemon surface it polls, all
# read-only and loopback-facing:
#
# 1. /api/config (new in 0.8.8). The Config tab reads it to show every
#    [daemon] parameter with its current value. Asserts the expected
#    keys are present AND that no secret leaks: TLS paths and the ack
#    API key are summarized to booleans (tls_configured, ack_api_key_set)
#    and the ack/archive storage paths are never echoed. This mirrors the
#    daemon-side unit test config_exposes_daemon_params_without_secrets.
# 2. /api/status (extended in 0.8.8). The Trends tab reads the capacity
#    caps and live depths from it. Asserts the new fields are present.
# 3. /api/energy. The Scrapers tab reads per-backend health from it.
#    Asserts the backends array shape and that no backend secret leaks.
# 4. /metrics. The six scalar gauges the upstream Grafana dashboard's
#    Energy / Carbon / Headroom panels query. Asserts all six are
#    registered and exposed (presence, not magnitude: they register at
#    startup and read 0 without traffic, which is enough to prove the
#    wiring; live magnitude is covered by grafana-dashboard).
#
# No traffic and no green backend are required: every check above is
# satisfied by a freshly-started daemon. Run against the lab daemon
# port-forwarded by scripts/port-forward.sh (default), or point
# DAEMON_URL at any reachable daemon.

set -euo pipefail

SCENARIO="query-monitor-api"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"
FAILURES=0
fail() { warn "$*"; FAILURES=$((FAILURES + 1)); }

step "Probe daemon at ${DAEMON_URL}"
curl -fsS "${DAEMON_URL}/api/status" >/dev/null 2>&1 \
  || die "daemon not reachable at ${DAEMON_URL}, run scripts/port-forward.sh start first"
ok "daemon reachable"

# --- 1. /api/config: params present, secrets absent ------------------------
step "GET /api/config (Config tab source)"
curl -fsS "${DAEMON_URL}/api/config" > "${TMP_DIR}/config.json" 2>/dev/null \
  || die "/api/config not reachable (daemon predates 0.8.8?)"

CONFIG_PARAMS=$(python3 - "${TMP_DIR}/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
# Keys the Config tab renders and the operator relies on.
required = [
    "listen_port", "max_active_traces", "trace_ttl_ms", "sampling_rate",
    "max_events_per_trace", "max_payload_size", "environment",
    "max_retained_findings", "ingest_queue_capacity", "analysis_queue_capacity",
    "api_enabled", "tls_configured", "ack_enabled", "ack_api_key_set",
    "correlation_enabled", "correlation_window_ms", "correlation_min_confidence",
    "correlation_max_tracked_pairs",
]
missing = [k for k in required if k not in cfg]
if missing:
    print("MISSING:" + ",".join(missing))
    sys.exit(0)
print("OK:%d" % len(cfg))
PY
)
if [[ "${CONFIG_PARAMS}" == OK:* ]]; then
  ok "/api/config exposes the expected [daemon] params (${CONFIG_PARAMS#OK:} keys)"
else
  fail "/api/config missing keys: ${CONFIG_PARAMS#MISSING:}"
fi

# Secret-leak gate. The allowlist response must never carry a secret
# field name or value: no api_key, no TLS/ack/archive paths.
SECRET_CHECK=$(python3 - "${TMP_DIR}/config.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
cfg = json.loads(raw)
forbidden_keys = ["api_key", "cert_path", "key_path", "storage_path",
                  "toml_path", "archive_path", "tls_cert", "tls_key"]
leaked_keys = [k for k in forbidden_keys if k in cfg]
# Belt and suspenders: scan the raw bytes for secret-bearing substrings
# a future field might reintroduce. tls_configured / ack_api_key_set are
# the sanctioned boolean summaries and must not trip this.
needles = ["acks.jsonl", "/var/lib/perf-sentinel", "BEGIN ", "-----"]
leaked_vals = [n for n in needles if n in raw]
if leaked_keys or leaked_vals:
    print("LEAK:" + ",".join(leaked_keys + leaked_vals))
else:
    print("CLEAN")
PY
)
if [ "${SECRET_CHECK}" = "CLEAN" ]; then
  ok "/api/config leaks no secret (paths/keys summarized to booleans)"
else
  fail "/api/config SECRET LEAK: ${SECRET_CHECK#LEAK:}"
fi

# --- 2. /api/status: new capacity fields -----------------------------------
step "GET /api/status (Trends tab capacity source)"
curl -fsS "${DAEMON_URL}/api/status" > "${TMP_DIR}/status.json" 2>/dev/null \
  || die "/api/status not reachable"
STATUS_CHECK=$(python3 - "${TMP_DIR}/status.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
required = ["max_active_traces", "analysis_queue_depth", "analysis_queue_capacity",
            "stored_findings", "max_retained_findings"]
missing = [k for k in required if k not in st]
print("MISSING:" + ",".join(missing) if missing else "OK")
PY
)
if [ "${STATUS_CHECK}" = "OK" ]; then
  ok "/api/status carries the 0.8.8 capacity fields"
else
  fail "/api/status missing capacity fields: ${STATUS_CHECK#MISSING:}"
fi

# --- 3. /api/energy: backends shape, no secret -----------------------------
step "GET /api/energy (Scrapers tab health source)"
curl -fsS "${DAEMON_URL}/api/energy" > "${TMP_DIR}/energy.json" 2>/dev/null \
  || die "/api/energy not reachable (daemon predates the endpoint?)"
ENERGY_CHECK=$(python3 - "${TMP_DIR}/energy.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
data = json.loads(raw)
backends = data.get("backends")
if not isinstance(backends, list) or not backends:
    print("BAD_SHAPE")
    sys.exit(0)
known = {"scaphandre", "kepler", "redfish", "cloud_energy", "electricity_maps"}
seen = {b.get("backend") for b in backends}
if "configured" not in backends[0] or "backend" not in backends[0]:
    print("BAD_ENTRY")
    sys.exit(0)
if not (seen & known):
    print("NO_KNOWN_BACKEND")
    sys.exit(0)
# Health endpoint must not echo a backend secret (Electricity Maps key).
for needle in ("api_key", "token", "password", "secret"):
    if needle in raw:
        print("LEAK:" + needle)
        sys.exit(0)
print("OK:%d" % len(backends))
PY
)
if [[ "${ENERGY_CHECK}" == OK:* ]]; then
  ok "/api/energy returns a well-formed backends array (${ENERGY_CHECK#OK:} backends), no secret"
else
  fail "/api/energy issue: ${ENERGY_CHECK}"
fi

# --- 4. /metrics: the six 0.8.8 gauges -------------------------------------
step "GET /metrics (Grafana Energy / Carbon / Headroom gauges)"
curl -fsS -H "Accept: application/openmetrics-text" "${DAEMON_URL}/metrics" \
  > "${TMP_DIR}/metrics.txt" 2>/dev/null || die "/metrics not reachable"
GAUGES=(perf_sentinel_energy_kwh perf_sentinel_carbon_gco2 perf_sentinel_max_active_traces \
        perf_sentinel_analysis_queue_capacity perf_sentinel_max_retained_findings \
        perf_sentinel_stored_findings)
MISSING_GAUGES=()
for g in "${GAUGES[@]}"; do
  grep -qE "^${g} " "${TMP_DIR}/metrics.txt" || MISSING_GAUGES+=("${g}")
done
if [ "${#MISSING_GAUGES[@]}" -eq 0 ]; then
  ok "all 6 capacity/energy/carbon gauges exposed on /metrics"
else
  fail "/metrics missing gauges: ${MISSING_GAUGES[*]}"
fi

# --- verdict ---------------------------------------------------------------
if [ "${FAILURES}" -eq 0 ]; then
  verdict="PASS"
else
  verdict="FAIL"
fi

step "Write report"
{
  echo "# query monitor data plane validation"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Daemon: ${DAEMON_URL}"
  echo
  echo "Validates the read-only daemon endpoints that back \`perf-sentinel"
  echo "query monitor\` (0.8.8): /api/config, the extended /api/status,"
  echo "/api/energy, and the six scalar /metrics gauges."
  echo
  echo "## Checks"
  echo
  echo "- /api/config params present: ${CONFIG_PARAMS}"
  echo "- /api/config secret-leak gate: ${SECRET_CHECK}"
  echo "- /api/status capacity fields: ${STATUS_CHECK}"
  echo "- /api/energy backends shape: ${ENERGY_CHECK}"
  if [ "${#MISSING_GAUGES[@]}" -eq 0 ]; then
    echo "- /metrics six gauges: all present"
  else
    echo "- /metrics six gauges: missing ${MISSING_GAUGES[*]}"
  fi
  echo
  echo "## Run again"
  echo
  echo '```bash'
  echo "make verify-query-monitor-api"
  echo "# against an arbitrary daemon:"
  echo "DAEMON_URL=http://localhost:24318 make verify-query-monitor-api"
  echo '```'
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict} (${FAILURES} check(s) failed), see ${REPORT}"
fi
