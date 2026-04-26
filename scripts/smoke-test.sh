#!/usr/bin/env bash
# End-to-end smoke test for the running lab.
# Exits non-zero on the first failed check, so it can wire into CI.
# Assumes `make up` has completed and port-forwards are running.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"

color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }

pass() { color_green "  PASS: $*"; }
fail() { color_red   "  FAIL: $*"; exit 1; }

echo "==> 1. All pods Running or Completed"
not_ready=$(kubectl get pods -A --no-headers \
  | awk '$4!="Running" && $4!="Completed" {print}' | wc -l | tr -d ' ')
if [ "${not_ready}" = "0" ]; then
  pass "all pods Ready"
else
  kubectl get pods -A | awk '$4!="Running" && $4!="Completed" {print}'
  fail "${not_ready} pod(s) not Ready"
fi

echo "==> 2. Grafana /api/health"
curl -fsS "${GRAFANA_URL}/api/health" >/dev/null 2>&1 \
  && pass "Grafana healthy" \
  || fail "Grafana not reachable at ${GRAFANA_URL}"

echo "==> 3. perf-sentinel daemon /api/status"
status=$(curl -fsS "${DAEMON_URL}/api/status") \
  || fail "daemon /api/status not reachable"
echo "${status}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = ('version', 'uptime_seconds', 'active_traces', 'stored_findings')
missing = [k for k in required if k not in d]
if missing:
    print(f'missing keys: {missing}', file=sys.stderr)
    sys.exit(1)
" && pass "daemon status OK (version $(echo "${status}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'))" \
  || fail "daemon status payload malformed"

echo "==> 4. perf-sentinel daemon /api/findings"
findings=$(curl -fsS "${DAEMON_URL}/api/findings") \
  || fail "daemon /api/findings not reachable"
echo "${findings}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert isinstance(d, list), 'findings must be a list'
" && pass "findings endpoint returns a list ($(echo "${findings}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') item(s))" \
  || fail "findings payload malformed"

echo "==> 5. Tempo /ready"
curl -fsS "${TEMPO_URL}/ready" >/dev/null 2>&1 \
  && pass "Tempo ready" \
  || fail "Tempo not ready at ${TEMPO_URL}"

echo "==> 6. Postgres reachable from cluster"
if [ ! -f "${REPO_ROOT}/.postgres-password" ]; then
  fail "missing .postgres-password (run make up first)"
fi
schemas=$(kubectl run -n db smoke-pgcheck --rm -i --restart=Never \
  --image=postgres:18.3-alpine \
  --env="PGPASSWORD=$(cat "${REPO_ROOT}/.postgres-password")" \
  --command -- psql -h postgres -U lab -d lab -tAc \
  "SELECT nspname FROM pg_namespace WHERE nspname IN ('orders','payments','notifications') ORDER BY nspname" 2>/dev/null \
  | grep -E '^(orders|payments|notifications)$' | sort | tr '\n' ',' | sed 's/,$//')
if [ "${schemas}" = "notifications,orders,payments" ]; then
  pass "Postgres has all 3 schemas"
else
  fail "Postgres missing schemas (got: ${schemas:-empty})"
fi

echo "==> 7. perf-sentinel /metrics exposes perf_sentinel_* metrics"
metric_count=$(curl -fsS "${DAEMON_URL}/metrics" \
  | grep -cE '^perf_sentinel_' || true)
if [ "${metric_count}" -gt 0 ]; then
  pass "${metric_count} perf_sentinel_* metric series exposed"
else
  fail "no perf_sentinel_* metrics found"
fi

color_green "==> Smoke test passed"
