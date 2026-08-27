#!/usr/bin/env bash
# Template-mutation pairing in `diff` (0.15.0).
#
# A refactor that changes a query's shape used to read as two unrelated events:
# the old finding "resolved" and a brand new one appeared, so a still-live
# anti-pattern looked fixed and a CI gate keyed on new_findings fired for a
# problem that was already there. `diff` now pairs the two into
# `mutated_findings` when the detector, service, endpoint and grouping match and
# only the normalized template moved.
#
# Hermetic CLI scenario: the binary under validation runs over committed trace
# fixtures, no cluster contact.
#
# 5 sub-tests:
#   1. a mutation pairs, and leaves neither a new nor a resolved finding
#   2. the pair is absent from SARIF, deliberately
#   3. the diff CSV export carries the pair
#   4. a severity escalation inside a mutation is visible on the pair
#   5. genuine ambiguity is never guessed, and a code anchor resolves it when
#      it can

set -euo pipefail

SCENARIO="diff-mutated-findings"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCENARIO_DIR}/fixtures"

LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
for f in before.json after.json ambiguous-before.json ambiguous-after.json \
         anchored-before.json anchored-after.json \
         escalation-before.json escalation-after.json; do
  [ -f "${FIXTURES_DIR}/${f}" ] || die "fixture missing: ${f}"
done
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
cp "${FIXTURES_DIR}"/*.json "${TMP_DIR}/"
ok "fixtures + image OK (${IMAGE})"

in_image() {
  docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"
}

# Run a diff and print "new resolved mutated" for the given fixture pair.
counts_of() {
  in_image diff --before "/workdir/$1-before.json" --after "/workdir/$1-after.json" \
    --format json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(len(d.get("new_findings", [])),
      len(d.get("resolved_findings", [])),
      len(d.get("mutated_findings", [])))
'
}

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# The plain pair is named before/after rather than <name>-before/-after.
cp "${TMP_DIR}/before.json" "${TMP_DIR}/simple-before.json"
cp "${TMP_DIR}/after.json"  "${TMP_DIR}/simple-after.json"

# === 1: a mutation pairs and consumes both sides ===
step "1. a template mutation pairs, leaving no new and no resolved finding"
if read -r n r m <<<"$(counts_of simple)" && [ "${n}" = "0" ] && [ "${r}" = "0" ] && [ "${m}" = "1" ]; then
  ok "0 new, 0 resolved, 1 mutated"
  record "mutation pairs" PASS "0/0/1"
else
  fail "got new=${n:-?} resolved=${r:-?} mutated=${m:-?}, expected 0/0/1"
  fail "1/1/0 is the pre-0.15.0 behaviour: the live anti-pattern reads as fixed"
  record "mutation pairs" FAIL "${n:-?}/${r:-?}/${m:-?}"
fi

# === 2: SARIF stays clean, on purpose ===
step "2. the pair is absent from SARIF (deliberate, not an oversight)"
if results="$(in_image diff --before /workdir/before.json --after /workdir/after.json \
                --format sarif 2>/dev/null | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["runs"][0]["results"]))
')" && [ "${results}" = "0" ]; then
  ok "0 SARIF results: a mutation is neither new nor resolved, so it raises no alert"
  record "sarif absence" PASS "0 results"
else
  fail "SARIF carried ${results:-?} results, expected 0"
  record "sarif absence" FAIL "${results:-?} results"
fi

# === 3: the dashboard carries the pair, in the panel and in the export ===
step "3. the dashboard embeds the pair and ships its export section"
# `report --before` takes a baseline REPORT, not traces, so analyze first.
# The CSV export itself is browser-side, so assert both halves: the pair is in
# the embedded payload, and the code that writes it to CSV is in the page.
if in_image analyze --input /workdir/before.json --format json > "${TMP_DIR}/before-report.json" 2>/dev/null \
   && in_image report --input /workdir/after.json --before /workdir/before-report.json \
        --output /workdir/diff.html >/dev/null 2>&1 \
   && python3 - "${TMP_DIR}/diff.html" <<'PY'
import json, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
missing = [t for t in ('"mutated"', "before_template", "diff-mut-table", "renderDiffMutTable")
           if t not in html]
if missing:
    sys.exit("missing from the dashboard: " + ", ".join(missing))
payload = re.search(r'<script id="report-data" type="application/json">(.*?)</script>', html, re.S)
if not payload:
    sys.exit("no embedded report payload")
pairs = (json.loads(payload.group(1)).get("diff") or {}).get("mutated_findings", [])
if len(pairs) != 1:
    sys.exit(f"expected 1 embedded mutated pair, got {len(pairs)}")
PY
then
  ok "1 pair embedded, with the panel table and the before_template export column"
  record "dashboard + export" PASS "pair embedded, export section present"
else
  fail "the dashboard does not carry the pair or its export section"
  record "dashboard + export" FAIL "see output above"
fi

# === 4: a severity escalation hidden in a mutation stays visible ===
step "4. an escalation inside a mutation is visible on the pair"
if out="$(in_image diff --before /workdir/escalation-before.json \
            --after /workdir/escalation-after.json --format json 2>/dev/null)" \
   && note="$(printf '%s' "${out}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pairs = d.get("mutated_findings", [])
assert len(pairs) == 1, f"expected 1 mutated pair, got {len(pairs)}"
before, after = pairs[0]["before"]["severity"], pairs[0]["after"]["severity"]
assert (before, after) == ("warning", "critical"), f"expected warning->critical, got {before}->{after}"
# The escalation never reaches severity_changes: the pair is its only witness,
# which is exactly why the text output has to render the transition.
assert not d.get("severity_changes"), "the escalation must not also appear in severity_changes"
print(f"{before} -> {after}, severity_changes empty")
')"; then
  ok "${note}"
  record "escalation visible" PASS "${note}"
else
  fail "the escalation is not carried on the pair"
  record "escalation visible" FAIL "see output above"
fi

step "4b. the text output renders the transition, not just the after severity"
if in_image diff --before /workdir/escalation-before.json \
     --after /workdir/escalation-after.json 2>/dev/null \
     | grep -q 'WARNING.*CRITICAL'; then
  ok "the mutated line shows both severities"
  record "escalation rendered" PASS "WARNING->CRITICAL on the line"
else
  fail "the mutated line shows only one severity, hiding the escalation"
  record "escalation rendered" FAIL "transition absent"
fi

# === 5: ambiguity is never guessed; an anchor resolves it when it can ===
step "5. ambiguity stays unpaired, a code anchor resolves it when it can"
read -r an ar am <<<"$(counts_of ambiguous)"
read -r kn kr km <<<"$(counts_of anchored)"
if [ "${an}" = "2" ] && [ "${ar}" = "1" ] && [ "${am}" = "0" ] \
   && [ "${kn}" = "1" ] && [ "${kr}" = "0" ] && [ "${km}" = "1" ]; then
  ok "two candidates under one anchor pair nothing (2 new, 1 resolved)"
  ok "distinct anchors pair the right one and leave the genuinely new one new"
  record "ambiguity" PASS "2/1/0 then 1/0/1"
else
  fail "ambiguous gave ${an:-?}/${ar:-?}/${am:-?}, expected 2/1/0"
  fail "anchored gave ${kn:-?}/${kr:-?}/${km:-?}, expected 1/0/1"
  record "ambiguity" FAIL "${an:-?}/${ar:-?}/${am:-?} then ${kn:-?}/${kr:-?}/${km:-?}"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Image: \`${IMAGE}\`"
  echo
  echo "| Sub-test | Verdict | Note |"
  echo "| --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"

step "Report written to ${REPORT}"
for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
