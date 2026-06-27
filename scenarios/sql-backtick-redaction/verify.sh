#!/usr/bin/env bash
# sql-backtick-redaction: validate the 0.9.2 normalize/sql.rs changes on the
# local batch CLI path (no cluster, no daemon).
#
#   1. MySQL backtick identifiers are preserved verbatim by the normalizer,
#      including a NUMERIC backtick identifier (`2024`) that the pre-0.9.2
#      tokenizer would have masked to `?`. Bound `id` literals still collapse
#      to `?`, so the six occurrences group as one n_plus_one_sql.
#   2. PostgreSQL bracket/array string literals (ARRAY['secret','pii'],
#      data['ssn']) are MASKED, never leaked. This is the most important
#      security fix in the batch: no string literal may appear in analyze
#      output. `[` is deliberately NOT a special identifier state, so the
#      `'...'` string path masks the contents.
#
# Both fixtures are committed native SpanEvent JSON; fixtures/generate.py
# regenerates them (stdlib-only). Uses the local release binary built from
# the perf-sentinel checkout under test.
set -euo pipefail

SCENARIO="sql-backtick-redaction"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"

BT_TEMPLATE=""
AR_TEMPLATE=""

# --- 1. backtick ------------------------------------------------------------
step "Backtick identifiers preserved (incl. numeric \`2024\`), N+1 grouped"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/backtick.native.json" --format json \
  > "${TMP_DIR}/backtick.json" 2>"${TMP_DIR}/backtick.err" \
  || die "analyze failed on backtick.native.json: $(tail -2 "${TMP_DIR}/backtick.err")"

BT_TEMPLATE="$(python3 -c "
import json
r=json.load(open('${TMP_DIR}/backtick.json'))
n1=[f for f in r['findings'] if f.get('type')=='n_plus_one_sql']
assert len(n1)==1, 'expected exactly 1 n_plus_one_sql, got %d (%s)' % (len(n1), [f.get('type') for f in r['findings']])
print(n1[0]['pattern']['template'])
")" || die "backtick: ${BT_TEMPLATE:-no n_plus_one_sql finding}"

EXPECTED_BT='SELECT `name`, `col2` FROM `2024` WHERE `id` = ?'
[ "${BT_TEMPLATE}" = "${EXPECTED_BT}" ] \
  || die "backtick template mismatch: got [${BT_TEMPLATE}] want [${EXPECTED_BT}]"
# Numeric backtick id must NOT have been masked to `?`.
echo "${BT_TEMPLATE}" | grep -qF '`2024`' || die "numeric backtick \`2024\` was masked (pre-0.9.2 regression)"
echo "${BT_TEMPLATE}" | grep -qF '`col2`' || die "alphanumeric backtick \`col2\` not preserved"
ok "template: ${BT_TEMPLATE}"

# --- 2. bracket / array redaction (security) --------------------------------
step "PostgreSQL bracket/array string literals masked, no leak"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/array-redaction.native.json" --format json \
  > "${TMP_DIR}/array.json" 2>"${TMP_DIR}/array.err" \
  || die "analyze failed on array-redaction.native.json: $(tail -2 "${TMP_DIR}/array.err")"

AR_TEMPLATE="$(python3 -c "
import json
r=json.load(open('${TMP_DIR}/array.json'))
fs=[f for f in r['findings']]
assert fs, 'no finding fired on the array fixture'
print(fs[0]['pattern']['template'])
")" || die "array: ${AR_TEMPLATE:-no finding}"

echo "${AR_TEMPLATE}" | grep -qF 'ARRAY[?, ?]' || die "ARRAY literals not masked: [${AR_TEMPLATE}]"
echo "${AR_TEMPLATE}" | grep -qF 'data[?]'     || die "subscript literal not masked: [${AR_TEMPLATE}]"
# Whole-output leak scan: params are never serialized, so any hit is a real leak.
if grep -oiE "secret|pii|ssn" "${TMP_DIR}/array.json"; then
  die "string literal leaked into analyze JSON output"
fi
ok "template: ${AR_TEMPLATE}  (no secret/pii/ssn leak)"

# --- 3. HTML render: masked template renders + exemplar surface check -------
# The 0.9.2 security fix is the NORMALIZED TEMPLATE (signature/grouping path),
# proven clean above on the canonical `analyze --format json` output. The HTML
# report ALSO embeds a raw example span (`target` = captured db.statement) as
# an exemplar. That raw exemplar is rendered verbatim and is OUTSIDE the three
# commits under test (normalize/sql.rs only; the report renderer is untouched).
# So we assert the masked template renders, and we OBSERVE — non-fatally —
# whether the raw exemplar surfaces literals from un-sanitized input.
step "HTML report: masked template renders; raw exemplar surface observed"
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${FIX}/array-redaction.native.json" \
  --output "${TMP_DIR}/array.html" >/dev/null 2>&1 || die "report --output failed"
grep -qF 'ARRAY[?, ?]' "${TMP_DIR}/array.html" || die "masked template absent from HTML report"
HTML_EXEMPLAR_LEAK="no"
if grep -qF "ARRAY['secret'" "${TMP_DIR}/array.html"; then
  HTML_EXEMPLAR_LEAK="yes"
  color_red "    note: HTML embeds the raw exemplar statement (ARRAY['secret', 'pii'])."
  color_red "          Pre-existing report-renderer behaviour, NOT touched by 0.9.2;"
  color_red "          the normalize fix (template/signature) is clean. Flag upstream."
fi
ok "masked template present in HTML; raw-exemplar leak=${HTML_EXEMPLAR_LEAK}"

# --- verdict ----------------------------------------------------------------
# PASS reflects the 0.9.2 change under test (normalize/sql.rs). The HTML
# exemplar observation is reported but does not gate this scenario.
verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo ""
  echo "| check | result |"
  echo "|---|---|"
  echo "| backtick template | \`${BT_TEMPLATE}\` |"
  echo "| numeric backtick \`2024\` preserved | yes |"
  echo "| array/subscript template | \`${AR_TEMPLATE}\` |"
  echo "| secret/pii/ssn leak in analyze JSON | none |"
  echo "| masked template renders in HTML | yes |"
  echo "| raw exemplar leak in HTML (out of scope) | ${HTML_EXEMPLAR_LEAK} |"
  echo ""
  if [ "${HTML_EXEMPLAR_LEAK}" = "yes" ]; then
    echo "> Observation: the normalized template (the 0.9.2 fix) masks bracket/array"
    echo "> string literals correctly on the canonical \`analyze --format json\` path."
    echo "> The HTML report additionally embeds a raw example span whose \`target\` is"
    echo "> the captured db.statement, so un-sanitized literals still appear in that"
    echo "> exemplar. The report renderer is NOT part of the three commits under test"
    echo "> (normalize/sql.rs only) — pre-existing behaviour, worth flagging upstream."
    echo ""
  fi
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
