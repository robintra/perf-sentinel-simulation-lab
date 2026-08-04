#!/usr/bin/env bash
# ack-lifecycle-warning: the full life of a CI acknowledgment on real
# artefacts — acked, fixed, not-run, and replayed.
#
# 0.9.28 reports an active TOML ack that suppressed nothing under the
# `unmatched_acknowledgment` warning, and the optional `service` /
# `source_endpoint` fields let it tell "the problem looks fixed, drop the
# entry" from "that endpoint did no I/O, keep the entry". The dangerous half
# is the guard: the warning must be derived ONLY from a fresh analysis of
# traces. A pre-computed report (a daemon `/api/export/report` snapshot, or a
# report JSON replayed through `report --input`) is already ack-filtered, so
# every still-useful entry would look unmatched there — and the tool would
# advise removing acks that are doing their job.
#
#   A1  the life cycle: finding -> acked (suppressed, no warning) -> fixed
#       ("looks fixed") -> endpoint not exercised ("proves nothing") -> an
#       entry without the optional fields (indeterminate, names both readings)
#   A2  the guard: no unmatched warning off a pre-computed report, whether it
#       comes from the daemon or from a replayed analyze JSON. A positive
#       control proves the same ack DOES warn on fresh traces, so a silent
#       assertion cannot pass vacuously.
#   A3  transport: diff carries the after run's warnings in text and in JSON,
#       and the field is additive (the lab's own jq consumer still works).
#
# Self-contained: local release binary only. No cluster, no Docker. The A2
# daemon leg uses a committed snapshot fixture, and additionally queries a
# live daemon when one is reachable.
set -uo pipefail

SCENARIO="ack-lifecycle-warning"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
DAEMON_URL="${DAEMON_URL:-http://localhost:14318}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"
rm -f "${REPORT}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }
FAILURES=0
pass() { ok "$2"; record "$1" "PASS" "$2"; }
fail() { color_red "    FAIL: $2"; record "$1" "FAIL" "$2"; FAILURES=$((FAILURES + 1)); }

# Count unmatched_acknowledgment warnings in a report JSON, and print the
# message tail so a wrong reading is visible rather than merely counted.
warn_count() { python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); raise SystemExit
w = [x for x in (d.get("warning_details") or [])
     if x.get("kind") == "unmatched_acknowledgment"]
print(len(w))
PY
}
warn_msg() { python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in (d.get("warning_details") or []):
    if x.get("kind") == "unmatched_acknowledgment":
        m = x.get("message", "")
        print(m[m.find("run:") + 5:].strip())
        break
PY
}
findings_n() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('findings',[])))" "$1"; }

step "0. Pre-flight"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
command -v python3 >/dev/null || die "python3 not on PATH"
for f in nplusone fixed elsewhere; do
  [ -f "${FIX}/${f}.native.json" ] || die "fixture missing: ${FIX}/${f}.native.json"
done
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
ok "binary ${BIN_VERSION}"

cd "${TMP_DIR}" || die "cannot enter ${TMP_DIR}"

# ---------------------------------------------------------------------------
step "A1.1: the N+1 fires and yields a signature"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/nplusone.native.json" \
  --no-acknowledgments --format json > raw.json 2>/dev/null \
  || die "analyze failed on the n+1 fixture"
SIG="$(python3 -c "
import json; d=json.load(open('raw.json'))
f=[x for x in d['findings'] if x['type']=='n_plus_one_sql']
print(f[0]['signature'] if f else '')")"
[ -n "${SIG}" ] || die "no n_plus_one_sql finding in the fixture (detection changed?)"
SVC="$(python3 -c "
import json; d=json.load(open('raw.json'))
f=[x for x in d['findings'] if x['type']=='n_plus_one_sql'][0]
print(f['service'], f['source_endpoint'])")"
ACK_SVC="${SVC%% *}"; ACK_EP="${SVC##* }"
pass "A1.1" "n_plus_one_sql on ${ACK_SVC} ${ACK_EP}"

# The entry copies service and source_endpoint straight out of the JSON, the
# way the docs tell an operator to write it.
write_ack() {  # $1 = target file, $2 = "full" | "bare"
  {
    echo "[[acknowledged]]"
    echo "signature = \"${SIG}\""
    echo "acknowledged_by = \"lab@example.com\""
    echo "acknowledged_at = \"2026-08-04\""
    echo "reason = \"known N+1, batching scheduled\""
    if [ "$2" = "full" ]; then
      echo "service = \"${ACK_SVC}\""
      echo "source_endpoint = \"${ACK_EP}\""
    fi
  } > "$1"
}
write_ack "${TMP_DIR}/.perf-sentinel-acknowledgments.toml" full
write_ack "${TMP_DIR}/bare.toml" bare

# ---------------------------------------------------------------------------
step "A1.2: the ack suppresses the finding and stays silent"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/nplusone.native.json" \
  --format json > acked.json 2>/dev/null
N="$(findings_n acked.json)"; W="$(warn_count acked.json)"
GATE="$(python3 -c "import json;print(json.load(open('acked.json'))['quality_gate']['passed'])")"
if [ "${N}" = "0" ] && [ "${W}" = "0" ] && [ "${GATE}" = "True" ]; then
  pass "A1.2" "finding suppressed, gate passed, no unmatched warning"
else
  fail "A1.2" "findings=${N} (want 0), warnings=${W} (want 0), gate=${GATE} (want True)"
fi

step "A1.3: same endpoint still does I/O, no finding -> looks fixed"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/fixed.native.json" \
  --format json > fixed.json 2>/dev/null
W="$(warn_count fixed.json)"; MSG="$(warn_msg fixed.json)"
if [ "${W}" = "1" ] && [[ "${MSG}" == *"looks fixed"* ]] && [[ "${MSG}" == *"${ACK_EP}"* ]]; then
  pass "A1.3" "names the endpoint and advises removal: ${MSG:0:80}"
else
  fail "A1.3" "warnings=${W} (want 1), message=[${MSG:0:120}]"
fi

step "A1.4: the acked endpoint emitted no I/O -> proves nothing"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/elsewhere.native.json" \
  --format json > elsewhere.json 2>/dev/null
W="$(warn_count elsewhere.json)"; MSG="$(warn_msg elsewhere.json)"
# The service is alive in this fixture (it serves other endpoints), so a
# match here would mean the check keys on the service alone, not the pair.
if [ "${W}" = "1" ] && [[ "${MSG}" == *"proves nothing"* ]] && [[ "${MSG}" == *"keep the entry"* ]]; then
  pass "A1.4" "same service, other endpoints busy, still says keep: ${MSG:0:80}"
else
  fail "A1.4" "warnings=${W} (want 1), message=[${MSG:0:120}]"
fi

step "A1.5: an entry without the optional fields stays indeterminate"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/fixed.native.json" \
  --acknowledgments bare.toml --format json > bare.json 2>/dev/null
W="$(warn_count bare.json)"; MSG="$(warn_msg bare.json)"
if [ "${W}" = "1" ] && [[ "${MSG}" == *"either fixed"* ]] \
   && [[ "${MSG}" == *"did not run"* ]] && [[ "${MSG}" != *"looks fixed"* ]]; then
  pass "A1.5" "offers both readings and points at the two fields"
else
  fail "A1.5" "warnings=${W} (want 1), message=[${MSG:0:120}]"
fi

# ---------------------------------------------------------------------------
step "A2.1: positive control — the same ack DOES warn on fresh traces"
# Without this, every A2 assertion below could pass simply because nothing
# was ever evaluated.
if [ "$(warn_count fixed.json)" = "1" ]; then
  pass "A2.1" "fresh analysis warns, so the silence below is meaningful"
else
  fail "A2.1" "no warning on fresh traces, the A2 guard checks would pass vacuously"
fi

step "A2.2: replayed analyze JSON produces no unmatched warning"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/fixed.native.json" \
  --no-acknowledgments --format json > precomputed.json 2>/dev/null
"${PERF_SENTINEL_LOCAL_BIN}" report --input precomputed.json --output replay.html 2>/dev/null
RC=$?
if [ "${RC}" -eq 0 ] && ! grep -q "unmatched_acknowledgment" replay.html \
   && ! grep -q "can be removed" replay.html; then
  pass "A2.2" "report --input on a pre-computed report advises nothing"
else
  fail "A2.2" "rc=${RC}, unmatched=$(grep -c unmatched_acknowledgment replay.html), removal advice=$(grep -c 'can be removed' replay.html)"
fi

step "A2.3: a daemon snapshot produces no unmatched warning"
SNAP="${FIX}/daemon-snapshot.json"
LIVE=""
if curl -fsS --max-time 5 "${DAEMON_URL}/api/export/report" > live-snapshot.json 2>/dev/null \
   && [ -s live-snapshot.json ]; then
  LIVE="live-snapshot.json"
fi
SNAP_FAIL=0
for src in "${SNAP}" ${LIVE}; do
  [ -f "${src}" ] || continue
  "${PERF_SENTINEL_LOCAL_BIN}" report --input "${src}" \
    --output "snap-$(basename "${src}" .json).html" 2>/dev/null
  if grep -q "unmatched_acknowledgment" "snap-$(basename "${src}" .json).html"; then
    SNAP_FAIL=$((SNAP_FAIL + 1))
    color_red "    leak on $(basename "${src}")"
  fi
done
if [ "${SNAP_FAIL}" -eq 0 ]; then
  pass "A2.3" "committed snapshot${LIVE:+ and live daemon export} stay silent"
else
  fail "A2.3" "${SNAP_FAIL} pre-computed report(s) advised removing an entry"
fi

# ---------------------------------------------------------------------------
step "A3: diff carries the after run's warnings, additively"
"${PERF_SENTINEL_LOCAL_BIN}" diff --before "${FIX}/nplusone.native.json" \
  --after "${FIX}/fixed.native.json" > diff.txt 2>/dev/null
"${PERF_SENTINEL_LOCAL_BIN}" diff --before "${FIX}/nplusone.native.json" \
  --after "${FIX}/fixed.native.json" --format json > diff.json 2>/dev/null
TEXT_OK=0; grep -q "Warnings (after run)" diff.txt && TEXT_OK=1
JSON_N="$(warn_count diff.json)"
# The lab's own consumer (output-formats-coverage) reads .new_findings; the
# added field must not break it.
LEGACY="$(python3 -c "
import json; print(len(json.load(open('diff.json')).get('new_findings', [])))" 2>/dev/null || echo ERR)"
if [ "${TEXT_OK}" = "1" ] && [ "${JSON_N}" = "1" ] && [ "${LEGACY}" != "ERR" ]; then
  pass "A3" "text block + warning_details in JSON, .new_findings still readable (${LEGACY})"
else
  fail "A3" "text=${TEXT_OK}, json warnings=${JSON_N} (want 1), legacy consumer=${LEGACY}"
fi

# ---------------------------------------------------------------------------
step "Summary"
VERDICT="PASS"; [ "${FAILURES}" -gt 0 ] && VERDICT="FAIL"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "Binary: \`${PERF_SENTINEL_LOCAL_BIN}\` (${BIN_VERSION})"
  echo ""
  echo "| check | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
  echo ""
  echo "Verdict: **${VERDICT}**"
} > "${REPORT}"

if [ "${FAILURES}" -gt 0 ]; then
  color_red "FAIL (${FAILURES}) — report at ${REPORT}"
  exit 1
fi
color_green "PASS — report at ${REPORT}"
