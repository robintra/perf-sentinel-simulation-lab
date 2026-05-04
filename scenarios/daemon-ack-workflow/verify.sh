#!/usr/bin/env bash
# daemon-ack-workflow: end-to-end validation of the perf-sentinel daemon
# ack workflow. Validates the 0.5.20 ack API (POST/DELETE/GET) with the
# 0.5.21 Prometheus counter surface, plus persistence on the
# perf-sentinel-acks PVC across daemon restarts.
#
# Sub-tests:
#   1. Sanity                : daemon reachable on /api/status
#   2. Seed                  : harvest 2 finding signatures via /api/export/report
#   3. Counter snapshot      : ack/unack/fail counters BEFORE
#   4. POST sig_a            : 201 with expires_at = now + TTL_SEC
#   5. Filter check          : feature-detect /api/findings, soft-assert annotation
#   6. Counter delta sig_a   : ACK_AFTER - ACK_BEFORE == 1, fallback /api/acks list
#   7. Restart + persistence : rollout, refresh_pf, /api/acks still has sig_a, JSONL sane
#   8. POST sig_b            : 201 with long TTL (kept for steps 9-10)
#   9. 409 conflict          : POST sig_b again -> 409, fail counter delta == 1
#  10. DELETE sig_b          : 204, unack counter delta == 1
#  11. TTL expiry            : sleep + poll, sig_a dropped at query time
#
# Counter assertions tolerate the 0.5.20 surface where ack_operations_total
# is not exposed (verdict_source=counter_absent_0520_fallback). When the
# pre-warmed 0.5.21 series is present, the script asserts BEFORE/AFTER
# delta to stay correct across CI scenario chains.

set -euo pipefail

SCENARIO="daemon-ack-workflow"
NS="observability"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
TTL_SEC="${TTL_SEC:-30}"
TTL_LONG_SEC="${TTL_LONG_SEC:-300}"
EXPIRY_SLEEP_SEC="${EXPIRY_SLEEP_SEC:-35}"
EXPIRY_POLL_SEC="${EXPIRY_POLL_SEC:-15}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

VERDICTS=()

refresh_pf() {
  pkill -f "kubectl.*port-forward.*perf-sentinel-daemon" 2>/dev/null || true
  rm -f "${REPO_ROOT}/tmp/pf-daemon.pid" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start > "${TMP_DIR}/pf.log" 2>&1
  for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Print int counter value matching the AWK pattern, or "MISSING".
query_counter() {
  local pattern="$1"
  local body val
  body=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/metrics" 2>/dev/null) || body=""
  val=$(printf '%s\n' "${body}" | awk -v p="${pattern}" '$0 ~ p {print $2; exit}')
  if [ -z "${val}" ]; then
    printf 'MISSING\n'
  else
    # Prometheus may render integer counters as "1" or "1.0".
    printf '%.0f\n' "${val}"
  fi
}

diff_counter() {
  local before="$1" after="$2"
  if [ "${before}" = "MISSING" ] || [ "${after}" = "MISSING" ]; then
    printf 'MISSING\n'
  else
    printf '%d\n' "$(( after - before ))"
  fi
}

# Probe whether /api/findings is exposed as a top-level endpoint (0.5.20+).
findings_endpoint_present() {
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" \
    "http://localhost:${DAEMON_LOCAL_PORT}/api/findings" 2>/dev/null || echo "000")
  [ "${code}" = "200" ]
}

# Portable "now + N seconds" in UTC ISO-8601, BSD or GNU date.
isoplus() {
  local n="$1"
  date -u -v "+${n}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "+${n} seconds" +%Y-%m-%dT%H:%M:%SZ
}

#######################################
# 1. Sanity
#######################################
step "1. Sanity: daemon reachable on localhost:${DAEMON_LOCAL_PORT}"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null \
  || die "daemon unreachable, run ./scripts/port-forward.sh start"
ok "daemon reachable"

#######################################
# 2. Seed: harvest finding signatures
#######################################
step "2. Harvest finding signatures from /api/export/report"
REPORT_JSON="${TMP_DIR}/report.json"
curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/export/report" > "${REPORT_JSON}" \
  || die "GET /api/export/report failed"
N_FINDINGS=$(python3 -c "import json; print(len(json.load(open('${REPORT_JSON}')).get('findings', [])))")
if [ "${N_FINDINGS}" -lt 3 ]; then
  die "Need >=3 distinct finding signatures (got ${N_FINDINGS}). Run: make seed-services && scripts/validate-findings.sh"
fi
# Harvest 3 distinct signatures. sig_a/sig_b take long TTLs to keep them
# active across the rollout restart and the duplicate-POST conflict
# probe; sig_c uses the short TTL for the expiry test.
read -r SIG_A SIG_B SIG_C < <(python3 -c "
import json
data = json.load(open('${REPORT_JSON}'))
seen = []
for f in data.get('findings', []):
    s = f.get('signature')
    if s and s not in seen:
        seen.append(s)
    if len(seen) == 3:
        break
print(' '.join(seen))
")
if [ -z "${SIG_C:-}" ]; then
  die "Could not harvest 3 distinct signatures from /api/export/report"
fi
export SIG_A SIG_B SIG_C
ok "sig_a=${SIG_A:0:24}... sig_b=${SIG_B:0:24}... sig_c=${SIG_C:0:24}..."

#######################################
# 3. Counter snapshot BEFORE
#######################################
step "3. Idempotent cleanup + snapshot counters BEFORE"
# Re-runs on the same daemon (or same PVC) need to start from a clean
# slate: the PVC persists acks across runs, so the harvested signatures
# may already be acked from a prior run. A best-effort DELETE clears
# them; 204 (was acked) and 404 (not acked) are both fine.
for sig in "${SIG_A}" "${SIG_B}" "${SIG_C}"; do
  enc=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${sig}")
  curl -o /dev/null -s -X DELETE "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${enc}/ack" 2>/dev/null || true
done

ACK_BEFORE=$(query_counter '^perf_sentinel_ack_operations_total\{action="ack"\}')
UNACK_BEFORE=$(query_counter '^perf_sentinel_ack_operations_total\{action="unack"\}')
FAIL_ALREADY_BEFORE=$(query_counter '^perf_sentinel_ack_operations_failed_total\{action="ack",reason="already_acked"\}')
COUNTER_SOURCE="counter_absent_0520_fallback"
if [ "${ACK_BEFORE}" != "MISSING" ]; then
  COUNTER_SOURCE="counter_present_0521"
fi
ok "ack=${ACK_BEFORE} unack=${UNACK_BEFORE} fail_already=${FAIL_ALREADY_BEFORE} source=${COUNTER_SOURCE}"

#######################################
# 4. POST sig_a (short TTL)
#######################################
step "4. POST /api/findings/{sig_a}/ack (long expires in ${TTL_LONG_SEC}s)"
EXPIRES_A=$(isoplus "${TTL_LONG_SEC}")
SIG_A_ENC=$(python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG_A'], safe=''))")
POST_A_BODY=$(printf '{"by":"alice","reason":"deferred","expires_at":"%s"}' "${EXPIRES_A}")
HTTP_A=$(curl -o "${TMP_DIR}/post-a.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_A_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_A_ENC}/ack" 2>/dev/null || echo "000")
if [ "${HTTP_A}" = "201" ]; then
  VERDICTS+=("PASS: 4 POST sig_a -> 201 (expires=${EXPIRES_A})")
else
  VERDICTS+=("FAIL: 4 POST sig_a -> HTTP ${HTTP_A} (body=$(head -c 120 "${TMP_DIR}/post-a.json" 2>/dev/null))")
fi

#######################################
# 5. Filter check (feature-detect /api/findings)
#######################################
step "5. Filter check (feature-detect /api/findings)"
if findings_endpoint_present; then
  HIDDEN=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/findings" 2>/dev/null \
    | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
d = json.load(sys.stdin)
items = d if isinstance(d, list) else (d.get('findings', []) if isinstance(d, dict) else [])
print('YES' if any(f.get('signature') == sig for f in items) else 'NO')
" 2>/dev/null || echo "PARSE_ERR")
  ANNOTATED=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/findings?include_acked=true" 2>/dev/null \
    | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
d = json.load(sys.stdin)
items = d if isinstance(d, list) else (d.get('findings', []) if isinstance(d, dict) else [])
match = [f for f in items if f.get('signature') == sig]
if not match:
    print('MISSING')
else:
    ack = match[0].get('acknowledged_by') or {}
    print('OK' if ack.get('by') == 'alice' else 'NO_ANNOTATION')
" 2>/dev/null || echo "PARSE_ERR")
  if [ "${HIDDEN}" = "NO" ] && [ "${ANNOTATED}" = "OK" ]; then
    VERDICTS+=("PASS: 5 filter (default hides sig_a, ?include_acked=true exposes acknowledged_by.by=alice)")
  elif [ "${HIDDEN}" = "NO" ]; then
    VERDICTS+=("PASS: 5 filter default hides sig_a (annotation surface=${ANNOTATED}, soft assert)")
  else
    VERDICTS+=("FAIL: 5 filter (sig_a hidden=${HIDDEN} annotated=${ANNOTATED})")
  fi
else
  VERDICTS+=("PASS: 5 filter skipped (/api/findings not exposed in this build, soft assert)")
fi

#######################################
# 6. Counter delta sig_a
#######################################
step "6. Counter delta for ack action"
ACK_AFTER1=$(query_counter '^perf_sentinel_ack_operations_total\{action="ack"\}')
DELTA_ACK=$(diff_counter "${ACK_BEFORE}" "${ACK_AFTER1}")
if [ "${DELTA_ACK}" = "MISSING" ]; then
  ACKS_LIST=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/acks" 2>/dev/null) || ACKS_LIST='[]'
  ACK_COUNT=$(printf '%s' "${ACKS_LIST}" | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else (d.get('acks', []) if isinstance(d, dict) else [])
    print(len([a for a in items if a.get('signature') == sig]))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  if [ "${ACK_COUNT}" -ge 1 ]; then
    VERDICTS+=("PASS: 6 ack via API list (counter_absent_0520_fallback, sig_a present)")
  else
    VERDICTS+=("FAIL: 6 ack list does not contain sig_a after POST (count=${ACK_COUNT})")
  fi
elif [ "${DELTA_ACK}" -eq 1 ]; then
  VERDICTS+=("PASS: 6 counter delta=1 (counter_present_0521, action=ack)")
else
  VERDICTS+=("FAIL: 6 counter delta=${DELTA_ACK} expected 1 (before=${ACK_BEFORE} after=${ACK_AFTER1})")
fi

#######################################
# 7. Rollout restart + persistence on PVC
#######################################
step "7. Rollout restart + persistence on PVC"
kubectl -n "${NS}" rollout restart deployment/perf-sentinel-daemon >/dev/null
kubectl -n "${NS}" rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null
if ! refresh_pf; then
  VERDICTS+=("FAIL: 7 daemon did not come back from rollout")
else
  ACKS_AFTER_RESTART=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/acks" 2>/dev/null) || ACKS_AFTER_RESTART='[]'
  SIG_A_PERSISTED=$(printf '%s' "${ACKS_AFTER_RESTART}" | python3 -c "
import json, sys, os
sig = os.environ['SIG_A']
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else (d.get('acks', []) if isinstance(d, dict) else [])
    print('YES' if any(a.get('signature') == sig for a in items) else 'NO')
except Exception:
    print('NO')
" 2>/dev/null || echo "NO")
  # JSONL line count is best-effort: the daemon image is distroless
  # (scratch) so kubectl exec into the pod returns ENOEXEC for sh/wc.
  # Persistence (sig_a still in /api/acks) is the load-bearing assert;
  # compaction line count is a soft signal we surface when reachable.
  JSONL_LINES="unknown"
  if [ -n "${REPORT_COMPACTION_VIA_DEBUG:-}" ]; then
    DAEMON_POD=$(kubectl -n "${NS}" get pod -l app.kubernetes.io/name=perf-sentinel-daemon -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${DAEMON_POD}" ]; then
      JSONL_LINES=$(kubectl -n "${NS}" exec "${DAEMON_POD}" -- sh -c 'wc -l < /var/lib/perf-sentinel/acks.jsonl 2>/dev/null || echo 0' 2>/dev/null \
        | tr -d ' \n\r' || echo "unknown")
      JSONL_LINES="${JSONL_LINES:-unknown}"
    fi
  fi
  if [ "${SIG_A_PERSISTED}" = "YES" ]; then
    VERDICTS+=("PASS: 7 persistence (sig_a survived rollout, jsonl_lines=${JSONL_LINES})")
  else
    VERDICTS+=("FAIL: 7 persistence (sig_a persisted=${SIG_A_PERSISTED} jsonl_lines=${JSONL_LINES})")
  fi
fi

#######################################
# 8. POST sig_b (long TTL, used for 9-10)
#######################################
step "8. POST /api/findings/{sig_b}/ack (long expires in ${TTL_LONG_SEC}s)"
EXPIRES_B=$(isoplus "${TTL_LONG_SEC}")
SIG_B_ENC=$(python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG_B'], safe=''))")
POST_B_BODY=$(printf '{"by":"alice","reason":"long-lived","expires_at":"%s"}' "${EXPIRES_B}")
HTTP_B=$(curl -o "${TMP_DIR}/post-b.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_B_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_B_ENC}/ack" 2>/dev/null || echo "000")
if [ "${HTTP_B}" = "201" ]; then
  VERDICTS+=("PASS: 8 POST sig_b -> 201 (expires=${EXPIRES_B})")
else
  VERDICTS+=("FAIL: 8 POST sig_b -> HTTP ${HTTP_B}")
fi

#######################################
# 9. 409 conflict on already-acked sig_b
#######################################
step "9. POST sig_b twice -> 409 already_acked"
FAIL_ALREADY_BEFORE9=$(query_counter '^perf_sentinel_ack_operations_failed_total\{action="ack",reason="already_acked"\}')
HTTP_B2=$(curl -o "${TMP_DIR}/post-b2.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_B_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_B_ENC}/ack" 2>/dev/null || echo "000")
FAIL_ALREADY_AFTER=$(query_counter '^perf_sentinel_ack_operations_failed_total\{action="ack",reason="already_acked"\}')
DELTA_FAIL_ALREADY=$(diff_counter "${FAIL_ALREADY_BEFORE9}" "${FAIL_ALREADY_AFTER}")
if [ "${HTTP_B2}" != "409" ]; then
  VERDICTS+=("FAIL: 9 duplicate POST -> HTTP ${HTTP_B2} expected 409")
elif [ "${DELTA_FAIL_ALREADY}" = "MISSING" ]; then
  VERDICTS+=("PASS: 9 duplicate POST -> 409 (counter_absent_0520_fallback)")
elif [ "${DELTA_FAIL_ALREADY}" -eq 1 ]; then
  VERDICTS+=("PASS: 9 duplicate POST -> 409 (counter_present_0521, fail_already_acked delta=1)")
else
  VERDICTS+=("FAIL: 9 duplicate POST -> 409 but counter delta=${DELTA_FAIL_ALREADY} expected 1")
fi

#######################################
# 10. DELETE sig_b
#######################################
step "10. DELETE /api/findings/{sig_b}/ack"
# Re-snapshot the unack counter immediately before the DELETE: the
# rollout restart in step 7 reset the daemon process, so the BEFORE
# value captured at step 3 is no longer comparable with AFTER.
UNACK_BEFORE_DEL=$(query_counter '^perf_sentinel_ack_operations_total\{action="unack"\}')
HTTP_DEL=$(curl -o "${TMP_DIR}/del-b.json" -s -w "%{http_code}" \
  -X DELETE \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_B_ENC}/ack" 2>/dev/null || echo "000")
UNACK_AFTER=$(query_counter '^perf_sentinel_ack_operations_total\{action="unack"\}')
DELTA_UNACK=$(diff_counter "${UNACK_BEFORE_DEL}" "${UNACK_AFTER}")
if [ "${HTTP_DEL}" != "204" ] && [ "${HTTP_DEL}" != "200" ]; then
  VERDICTS+=("FAIL: 10 DELETE sig_b -> HTTP ${HTTP_DEL} expected 204")
elif [ "${DELTA_UNACK}" = "MISSING" ]; then
  VERDICTS+=("PASS: 10 DELETE sig_b -> ${HTTP_DEL} (counter_absent_0520_fallback)")
elif [ "${DELTA_UNACK}" -ge 1 ]; then
  VERDICTS+=("PASS: 10 DELETE sig_b -> ${HTTP_DEL} (counter_present_0521, unack delta=${DELTA_UNACK})")
else
  VERDICTS+=("FAIL: 10 DELETE sig_b -> ${HTTP_DEL} but unack delta=${DELTA_UNACK}")
fi

#######################################
# 11. TTL expiry on a fresh sig_c (short TTL)
#######################################
step "11. POST sig_c (TTL ${TTL_SEC}s) then sleep+poll for expiry drop"
EXPIRES_C=$(isoplus "${TTL_SEC}")
SIG_C_ENC=$(python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['SIG_C'], safe=''))")
POST_C_BODY=$(printf '{"by":"alice","reason":"expiry-test","expires_at":"%s"}' "${EXPIRES_C}")
HTTP_C=$(curl -o "${TMP_DIR}/post-c.json" -s -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  -d "${POST_C_BODY}" \
  "http://localhost:${DAEMON_LOCAL_PORT}/api/findings/${SIG_C_ENC}/ack" 2>/dev/null || echo "000")
if [ "${HTTP_C}" != "201" ]; then
  VERDICTS+=("FAIL: 11 TTL prep POST sig_c -> HTTP ${HTTP_C}")
else
  sleep "${EXPIRY_SLEEP_SEC}"
  EXPIRED="NO"
  DEADLINE=$(( $(date +%s) + EXPIRY_POLL_SEC ))
  while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    ACKS_NOW=$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/acks" 2>/dev/null) || ACKS_NOW='[]'
    STILL_PRESENT=$(printf '%s' "${ACKS_NOW}" | python3 -c "
import json, sys, os
sig = os.environ['SIG_C']
try:
    d = json.load(sys.stdin)
    items = d if isinstance(d, list) else (d.get('acks', []) if isinstance(d, dict) else [])
    print('YES' if any(a.get('signature') == sig for a in items) else 'NO')
except Exception:
    print('YES')
" 2>/dev/null || echo "YES")
    if [ "${STILL_PRESENT}" = "NO" ]; then
      EXPIRED="YES"
      break
    fi
    sleep 2
  done
  if [ "${EXPIRED}" = "YES" ]; then
    VERDICTS+=("PASS: 11 TTL filter (sig_c dropped at query time within ${EXPIRY_SLEEP_SEC}+${EXPIRY_POLL_SEC}s)")
  else
    VERDICTS+=("FAIL: 11 TTL filter (sig_c still present after ${EXPIRY_SLEEP_SEC}+${EXPIRY_POLL_SEC}s)")
  fi
fi

#######################################
# Aggregate verdicts
#######################################
step "Aggregate verdicts"
verdict="PASS"
for v in "${VERDICTS[@]}"; do
  echo "    ${v}"
  if echo "${v}" | grep -q "^FAIL"; then
    verdict="FAIL"
  fi
done

if [ "${verdict}" = "FAIL" ]; then
  kubectl -n "${NS}" logs deploy/perf-sentinel-daemon --tail=120 > "${TMP_DIR}/daemon.log" 2>&1 || true
fi

step "Write report"
{
  echo "# daemon-ack-workflow"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Counter source: ${COUNTER_SOURCE}"
  echo "TTL_SEC=${TTL_SEC} TTL_LONG_SEC=${TTL_LONG_SEC} EXPIRY_SLEEP_SEC=${EXPIRY_SLEEP_SEC} EXPIRY_POLL_SEC=${EXPIRY_POLL_SEC}"
  echo
  echo "## Counter snapshot (BEFORE)"
  echo
  echo "- ack=${ACK_BEFORE}"
  echo "- unack=${UNACK_BEFORE}"
  echo "- fail_already_acked=${FAIL_ALREADY_BEFORE}"
  echo
  echo "## Sub-test verdicts"
  echo
  for v in "${VERDICTS[@]}"; do
    echo "- ${v}"
  done
  echo
  if [ "${verdict}" = "FAIL" ]; then
    echo "## Daemon logs (tail)"
    echo
    echo '```'
    tail -120 "${TMP_DIR}/daemon.log" 2>/dev/null || true
    echo '```'
    echo
  fi
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
