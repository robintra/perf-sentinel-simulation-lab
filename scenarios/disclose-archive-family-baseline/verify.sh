#!/usr/bin/env bash
# Archive-family keying of the drop baseline (0.15.0, schema v1.7).
#
# Each archived window carries a cumulative `drops` counter, and `disclose`
# folds consecutive values into the period's `windows_dropped`. The counter is
# daemon-lifetime, so the fold has to keep a baseline across a rotation while
# never carrying one into an unrelated archive: `disclose` takes a LIST of
# inputs, and diffing one host's counter against another's would invent both a
# restart and drops that never happened.
#
# Hermetic CLI scenario (same family as disclose / intent-validator): the
# binary under validation runs over committed fixtures, no cluster contact.
#
# Fixtures under fixtures/, deliberately overlapping so a keying regression is
# arithmetically visible rather than merely plausible:
#
#   hosts/host-a.ndjson   drops 0, 3, 3, 7   -> own deltas 3 + 0 + 4 = 7
#   hosts/host-b.ndjson   drops 5, 5, 9, 9   -> own deltas 0 + 4 + 0 = 4
#     Correct total 11 with 0 resets. A shared baseline sorts a before b, reads
#     b's opening 5 as a decrease from a's closing 7, and reports 16 with 1
#     reset. The two answers cannot be confused.
#
#   rotated/archive-20260601T090000000000000Z.ndjson   drops 2, 5
#   rotated/archive.ndjson                             drops 9, 12
#     Same family (directory + stem, rotation stamp stripped). Correct total 10:
#     3 within the rotated file, 4 ACROSS the boundary, 3 within the active one.
#     A per-file baseline loses the boundary delta and reports 6.
#
# 3 sub-tests:
#   1. two hosts stay independent   (11 dropped, 0 resets)
#   2. a rotation keeps its delta   (10 dropped, 0 resets)
#   3. a genuine restart is still counted, and only once

set -euo pipefail

SCENARIO="disclose-archive-family-baseline"
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

PERIOD_ARGS=(--period-type calendar-quarter --from 2026-04-01 --to 2026-06-30)

step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
for f in hosts/host-a.ndjson hosts/host-b.ndjson \
         rotated/archive-20260601T090000000000000Z.ndjson rotated/archive.ndjson \
         org-config.toml; do
  [ -f "${FIXTURES_DIR}/${f}" ] || die "fixture missing: ${f}"
done
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
cp -R "${FIXTURES_DIR}/." "${TMP_DIR}/"
ok "fixtures + image OK (${IMAGE})"

in_image() {
  docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"
}

# Read the two chain counters out of a disclose report.
drops_of() {
  python3 - "$1" <<'PY'
import json, sys
chain = json.load(open(sys.argv[1]))["integrity"]["trace_integrity_chain"]
print(f'{chain.get("windows_dropped")} {chain.get("drop_counter_resets")}')
PY
}

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# === 1: two unrelated hosts keep independent baselines ===
step "1. two hosts, one disclose run: baselines stay independent"
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/hosts/host-a.ndjson --input /workdir/hosts/host-b.ndjson \
     --output /workdir/out-hosts.json --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && read -r dropped resets <<<"$(drops_of "${TMP_DIR}/out-hosts.json")" \
   && [ "${dropped}" = "11" ] && [ "${resets}" = "0" ]; then
  ok "11 dropped, 0 resets (7 within host-a, 4 within host-b)"
  record "independent hosts" PASS "11 dropped / 0 resets"
else
  fail "got '${dropped:-?}' dropped / '${resets:-?}' resets, expected 11 / 0"
  fail "16 / 1 is the shared-baseline regression: host-b's opening value read as host-a's restart"
  record "independent hosts" FAIL "got ${dropped:-?} / ${resets:-?}"
fi

# === 2: a rotation of one family keeps the delta across the boundary ===
step "2. one family, two rotated files: the boundary delta survives"
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/rotated \
     --output /workdir/out-rotated.json --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && read -r dropped resets <<<"$(drops_of "${TMP_DIR}/out-rotated.json")" \
   && [ "${dropped}" = "10" ] && [ "${resets}" = "0" ]; then
  ok "10 dropped, 0 resets (3 + 4 across the rotation + 3)"
  record "rotation boundary" PASS "10 dropped / 0 resets"
else
  fail "got '${dropped:-?}' dropped / '${resets:-?}' resets, expected 10 / 0"
  fail "6 is the per-file-baseline regression: the delta across the rotation is lost"
  record "rotation boundary" FAIL "got ${dropped:-?} / ${resets:-?}"
fi

# === 3: a real restart inside one family is still counted, once ===
step "3. a genuine restart within one family is counted once"
mkdir -p "${TMP_DIR}/restart"
python3 - "${TMP_DIR}/hosts/host-a.ndjson" "${TMP_DIR}/restart/archive.ndjson" <<'PY'
import json, sys
src = [json.loads(l) for l in open(sys.argv[1])]
# 4 -> 9 -> 2 -> 6: one rise (+5), then a decrease that can only be a restart
# (the post-restart value is itself the loss, the counter began again at zero,
# +2), then a further rise (+4). 11 dropped, exactly one reset.
with open(sys.argv[2], "w") as out:
    for line, drops in zip(src, (4, 9, 2, 6)):
        line["drops"] = drops
        out.write(json.dumps(line, sort_keys=True) + "\n")
PY
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/restart \
     --output /workdir/out-restart.json --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && read -r dropped resets <<<"$(drops_of "${TMP_DIR}/out-restart.json")" \
   && [ "${resets}" = "1" ] && [ "${dropped}" = "11" ]; then
  ok "11 dropped, 1 reset (5 rising, 2 carried at the restart, 4 after)"
  record "restart counted once" PASS "11 dropped / 1 reset"
else
  fail "got '${dropped:-?}' dropped / '${resets:-?}' resets, expected 11 / 1"
  record "restart counted once" FAIL "got ${dropped:-?} / ${resets:-?}"
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
