#!/usr/bin/env bash
# rpc-carrier-parity: since product 0.9.8 the ingest admits OTel RPC
# semconv spans (rpc.system + rpc.service/rpc.method, CLIENT-kind only)
# as outbound calls - the prod-topology-replay slice no longer needs its
# synthetic `http.url = http://<dm>/<interface>` carrier. This gate
# rewrites the committed Alibaba slice onto the real rpc.* keys and
# asserts the RPC ingest path carries the full topological detector
# surface at production scale, against the carrier baseline analyzed
# in-run.
#
# Known, deliberate divergence: the HTTP normalizer strips the URL host,
# so the carrier merges calls to DIFFERENT dm services sharing an
# interface name into one "POST /<interface>" group - false redundancy
# merges the RPC target "<dm>/<interface>" correctly keeps apart. On
# this slice: 10 of the baseline's redundant_http findings are such
# false merges. redundant_http is therefore floored + recorded, not
# equality-asserted; the four topology classes and the admission counts
# must match exactly.
#
# Assertions (see README.md):
#   B0     die-guard: the committed carrier slice analyzes with findings
#          (prod-topology-replay already stamps this corpus)
#   G1-G3  die-guards: each variant carries the intended shape (client:
#          no carrier keys, rpc.service on every span; fallback: neither
#          carrier nor rpc.service, span-name is the only target;
#          server: every span kind CLIENT->SERVER)
#   P1     client == fallback exactly (attribute target and span-name
#          fallback are the same admission path)
#   P2     client vs baseline: identical traces_analyzed +
#          events_processed (admission parity) and identical counts on
#          the four topology classes (chatty_service, excessive_fanout,
#          n_plus_one_http, serialized_calls)
#   P3     redundant_http on client: > 0, count recorded against the
#          baseline with the documented host-strip delta
#   P4     server variant: zero findings (the CLIENT kind-gate; rpc.* is
#          set on inbound handler spans too and must not double-count)
set -uo pipefail

SCENARIO="rpc-carrier-parity"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
SLICE="${SCRIPT_DIR}/../prod-topology-replay/fixtures/alibaba-slice.ndjson"

TOPOLOGY_CLASSES="chatty_service excessive_fanout n_plus_one_http serialized_calls"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS - $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL - $2"; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
command -v python3 >/dev/null 2>&1 || die "python3 required"
[ -s "${SLICE}" ] || die "missing fixture ${SLICE} - run make fetch-prod-topology first"

run_analyze() {  # $1 = input file, $2 = tag ; json to out-<tag>.json, rc passthrough
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$1" \
    --format json > "${TMP_DIR}/out-$2.json" 2> "${TMP_DIR}/err-$2.txt"
}

traces_analyzed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["analysis"]["traces_analyzed"])' "${TMP_DIR}/out-$1.json"; }

events_processed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("analysis",{}).get("events_processed","n/a"))' "${TMP_DIR}/out-$1.json"; }

class_counts() {  # sorted "class=count" pairs ; findings JSON (bare or wrapped)
  python3 -c '
import json, sys
from collections import Counter
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
c = Counter(u(it).get("type", "") for it in items)
c.pop("", None)
print(" ".join(f"{k}={v}" for k, v in sorted(c.items())))' "${TMP_DIR}/out-$1.json"
}

count_of() {  # $1 = "class=count ..." string, $2 = class ; 0 when absent
  local pair
  for pair in $1; do
    [ "${pair%%=*}" = "$2" ] && { echo "${pair#*=}"; return; }
  done
  echo 0
}

# Count key OCCURRENCES, not matching lines: one minified request per line
# holds many spans, so `grep -c` (lines) would mask a partial transform.
keycount() { grep -o "$2" "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ── B0: carrier baseline (die-guard) ────────────────────────────────────────
step "B0: analyze the committed carrier slice (in-run baseline)"
run_analyze "${SLICE}" base || die "analyze failed on the carrier slice: $(tail -2 "${TMP_DIR}/err-base.txt")"
BASE_TA="$(traces_analyzed base)"
BASE_EV="$(events_processed base)"
BASE_COUNTS="$(class_counts base)"
[ "${BASE_TA}" -gt 0 ] || die "baseline analyzed zero traces"
[ -n "${BASE_COUNTS}" ] || die "baseline produced zero findings - parity would be vacuous (fixture or detector regression)"
ok "baseline: traces=${BASE_TA}, events=${BASE_EV}, findings [${BASE_COUNTS}]"

# ── generate + G1-G3 shape die-guards ───────────────────────────────────────
step "generate the three rpc.* variants + guard their shapes"
for m in client fallback server; do
  python3 "${SCRIPT_DIR}/rpcify.py" "${m}" "${SLICE}" "${TMP_DIR}/${m}.ndjson" \
    > "${TMP_DIR}/${m}.stats" || die "rpcify.py ${m} failed"
  ok "${m}: $(cat "${TMP_DIR}/${m}.stats")"
done

RPC_SYSTEMS="$(keycount "${SLICE}" '"key":"rpc.system"')"
for m in client server; do
  [ "$(keycount "${TMP_DIR}/${m}.ndjson" '"key":"http.url"')" -eq 0 ] || die "G1: ${m} still carries http.url"
  [ "$(keycount "${TMP_DIR}/${m}.ndjson" '"key":"rpc.service"')" -eq "${RPC_SYSTEMS}" ] \
    || die "G1: ${m} rpc.service count != span count ${RPC_SYSTEMS} - partial transform"
done
ok "G1: client/server carry rpc.service on every span, no carrier"
[ "$(keycount "${TMP_DIR}/fallback.ndjson" '"key":"http.url"')" -eq 0 ] || die "G2: fallback still carries http.url"
[ "$(keycount "${TMP_DIR}/fallback.ndjson" '"key":"rpc.service"')" -eq 0 ] || die "G2: fallback carries rpc.service - span-name path not isolated"
ok "G2: fallback has neither carrier nor rpc.service (span-name is the only target)"
[ "$(keycount "${TMP_DIR}/server.ndjson" '"kind":3')" -eq 0 ] || die "G3: server variant still has CLIENT spans"
[ "$(keycount "${TMP_DIR}/server.ndjson" '"kind":2')" -eq "${RPC_SYSTEMS}" ] || die "G3: server variant kind rewrite incomplete"
ok "G3: server variant is all SERVER-kind"

for m in client fallback server; do
  run_analyze "${TMP_DIR}/${m}.ndjson" "${m}" || die "analyze exited non-zero on ${m}: $(tail -2 "${TMP_DIR}/err-${m}.txt")"
done
# A pre-RPC binary silently drops every rpc.* span as not_io - that is a
# stale-binary infra error, not a parity finding.
[ "$(traces_analyzed client)" -gt 0 ] \
  || die "client variant analyzed zero traces - binary predates RPC ingest (rebuild at >= 0.9.8)"

# ── P1: attribute target == span-name fallback, exactly ─────────────────────
step "P1: client and fallback variants are identical"
C_TA="$(traces_analyzed client)"; C_EV="$(events_processed client)"; C_COUNTS="$(class_counts client)"
F_TA="$(traces_analyzed fallback)"; F_EV="$(events_processed fallback)"; F_COUNTS="$(class_counts fallback)"
if [ "${C_TA}" = "${F_TA}" ] && [ "${C_EV}" = "${F_EV}" ] && [ "${C_COUNTS}" = "${F_COUNTS}" ]; then
  assert_pass "P1" "rpc.service/rpc.method and span-name fallback agree: traces=${C_TA}, events=${C_EV}, findings [${C_COUNTS}]"
else
  assert_fail "P1" "client (traces=${C_TA}, events=${C_EV}, [${C_COUNTS}]) != fallback (traces=${F_TA}, events=${F_EV}, [${F_COUNTS}])"
fi

# ── P2: admission parity + topology-class parity vs the carrier ─────────────
step "P2: rpc.* admission and topology classes match the carrier baseline"
DIFFS=""
[ "${C_TA}" = "${BASE_TA}" ] || DIFFS="${DIFFS} traces:${C_TA}!=${BASE_TA}"
[ "${C_EV}" = "${BASE_EV}" ] || DIFFS="${DIFFS} events:${C_EV}!=${BASE_EV}"
for cls in ${TOPOLOGY_CLASSES}; do
  BC="$(count_of "${BASE_COUNTS}" "${cls}")"
  CC="$(count_of "${C_COUNTS}" "${cls}")"
  [ "${BC}" = "${CC}" ] || DIFFS="${DIFFS} ${cls}:${CC}!=${BC}"
done
if [ -z "${DIFFS}" ]; then
  assert_pass "P2" "traces=${C_TA}, events=${C_EV} and all four topology classes equal the carrier baseline"
else
  assert_fail "P2" "rpc.* variant diverges from carrier:${DIFFS}"
fi

# ── P3: redundant_http floored, host-strip delta recorded ───────────────────
step "P3: redundant_http present; carrier host-strip delta recorded"
BASE_RED="$(count_of "${BASE_COUNTS}" redundant_http)"
C_RED="$(count_of "${C_COUNTS}" redundant_http)"
if [ "${C_RED}" -gt 0 ]; then
  assert_pass "P3" "redundant_http=${C_RED} (carrier baseline ${BASE_RED}; delta $((BASE_RED - C_RED)) = carrier merges of same-interface calls to different dm hosts)"
else
  assert_fail "P3" "rpc.* variant found zero redundant_http (baseline ${BASE_RED})"
fi

# ── P4: SERVER-kind spans are rejected ──────────────────────────────────────
step "P4: the CLIENT kind-gate drops the server-side twins"
S_TOTAL="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
print(len(items))' "${TMP_DIR}/out-server.json")"
if [ "${S_TOTAL}" -eq 0 ]; then
  assert_pass "P4" "SERVER-kind rpc.* corpus yields zero findings (traces=$(traces_analyzed server))"
else
  assert_fail "P4" "SERVER-kind rpc.* corpus yielded ${S_TOTAL} findings - kind-gate broken, every hop would double-count"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "perf-sentinel's OTel RPC semconv ingest vs the synthetic HTTP carrier:"
  echo "the committed Alibaba slice rewritten onto real rpc.* keys must carry"
  echo "the same admission and topological detector surface, and SERVER-kind"
  echo "twins must be rejected."
  echo ""
  echo "| assertion | result |"
  echo "|---|---|"
  for row in "${SUMMARY[@]}"; do
    printf "| %s | %s |\n" "${row%%|*}" "${row#*|}"
  done
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  color_green "PASS - report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) - report at ${REPORT}"
fi
