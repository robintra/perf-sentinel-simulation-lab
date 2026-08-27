#!/usr/bin/env bash
# The payload the IDE plugin actually parses, captured from a running Hub.
#
# The plugin's parser is exercised only against hand-written JSON in its own
# repository, and the Hub's serializer only against its own tests. Neither has
# ever seen the other. Every field the plugin marks required is a field the Hub
# is free to rename, and nothing in either CI would notice.
#
# This scenario issues EXACTLY the request `findingsUri()` builds, asserts the
# payload carries what the parser requires, and writes the raw response into the
# plugin repository as a fixture. The plugin's HubContractTest then replays it
# through the real `DaemonClient` over a loopback HTTP server. Refreshing the
# fixture is a deliberate act: run this scenario, review the diff, commit it.
#
# Known gap, stated rather than papered over: no finding in this lab carries a
# `code_location`. The OpenTelemetry Java agent attaches no `code.*` attributes
# to JDBC spans, so the anchor the plugin navigates on is absent from every
# JVM-instrumented service here. The parse contract is therefore real and the
# navigation contract is not, and it is the plugin's own JavaAnchorResolverTest
# that keeps covering anchors. A captured fixture with a fabricated anchor would
# have proven nothing about the daemon's conventions.

set -euo pipefail

SCENARIO="hub-plugin-contract"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"

HUB_PORT="${HUB_LOCAL_PORT:-8080}"
ORDER_PORT="${HUB_CONTRACT_ORDER_PORT:-18096}"
SERVICE="${HUB_CONTRACT_SERVICE:-order-service}"
PLUGIN_REPO="${PERF_SENTINEL_PLUGIN_REPO_PATH:-${HOME}/IdeaProjects/PerfSentinelJetBrainsPlugin}"
FIXTURE_REL="src/test/resources/hub-contract/lab-order-service.json"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PF_ORDER_PID=""
cleanup() { [ -n "${PF_ORDER_PID}" ] && kill "${PF_ORDER_PID}" 2>/dev/null || true; }
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null \
  || die "the Hub is not reachable on ${HUB_PORT}. Run: make seed-hub-local && make port-forward"
kubectl -n shop get deploy/order-service >/dev/null 2>&1 \
  || die "no order-service in the cluster. Run: make seed-services"
ok "Hub reachable, ${SERVICE} deployed"

# === 1: the request the plugin builds returns findings ===
step "1. the plugin's own query returns a non-empty payload"
# Byte-for-byte the URI findingsUri() builds. Hardcoded rather than
# reconstructed so a change on either side shows up as a diff here.
QUERY="/api/findings?service=${SERVICE}&limit=1000&include_acked=true"
kubectl -n shop port-forward svc/order-service "${ORDER_PORT}:8080" \
  >"${TMP_DIR}/pf-order.log" 2>&1 &
PF_ORDER_PID=$!
disown "${PF_ORDER_PID}" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf -o /dev/null "http://127.0.0.1:${ORDER_PORT}/actuator/health" 2>/dev/null && break
  sleep 0.5
done
# Drive a little traffic so the capture is never an empty array, whatever ran
# before. The daemon pushes on its own flush interval.
for _ in 1 2 3; do
  curl -sf -o /dev/null -X POST \
    "http://127.0.0.1:${ORDER_PORT}/api/fault/n-plus-one-sql?items=15" || true
done
PAYLOAD="${TMP_DIR}/payload.json"
COUNT=0
for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${HUB_PORT}${QUERY}" > "${PAYLOAD}" 2>/dev/null || true
  COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${PAYLOAD}" 2>/dev/null || echo 0)"
  [ "${COUNT}" -gt 0 ] && break
  sleep 2
done
if [ "${COUNT}" -gt 0 ]; then
  ok "${COUNT} finding(s) returned for ${SERVICE}"
  record "plugin query returns findings" PASS "${COUNT} findings"
else
  fail "the plugin's query returned an empty array"
  record "plugin query returns findings" FAIL "0 findings"
  die "nothing to capture"
fi

# === 2: every field the parser marks required is present ===
step "2. the payload carries everything the plugin's parser requires"
if python3 - "${PAYLOAD}" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
assert isinstance(rows, list) and rows, "not a non-empty array"
# Mirrors parseFinding() in the plugin's FindingContract.kt. `requiredX` there
# throws, and parseFindings drops the row rather than the batch, so a renamed
# field would silently empty the tool window instead of erroring.
required_envelope = ["stored_at_ms", "finding"]
required_finding = ["type", "severity", "trace_id", "service", "source_endpoint",
                    "pattern", "suggestion", "first_timestamp", "last_timestamp"]
required_pattern = ["template", "occurrences", "window_ms", "distinct_params"]
# The six keys the Hub adds on top; the plugin ignores them today but the
# tool window's status column reads `status` and `sources`.
hub_owned = ["first_seen", "last_seen", "max_confidence", "sources", "status"]
for i, row in enumerate(rows):
    for field in required_envelope:
        assert field in row, f"row {i}: envelope lacks {field}"
    for field in hub_owned:
        assert field in row, f"row {i}: the Hub did not stamp {field}"
    finding = row["finding"]
    for field in required_finding:
        assert field in finding, f"row {i}: finding lacks {field}"
    for field in required_pattern:
        assert field in finding["pattern"], f"row {i}: pattern lacks {field}"
    assert isinstance(row["stored_at_ms"], int), f"row {i}: stored_at_ms is not an integer"
print(f"{len(rows)} rows, all parser-required fields present")
PY
then
  ok "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${PAYLOAD}") row(s) satisfy the parser contract"
  record "parser contract satisfied" PASS "all required fields present"
else
  fail "the payload is missing a field the plugin's parser requires"
  record "parser contract satisfied" FAIL "missing required field"
fi

# === 3: the capture is produced, and installed only when asked ===
step "3. the fixture is captured"
# Always written here, so verifying is read-only. Refreshing the plugin's
# committed fixture is a deliberate act, not a side effect of a gate run:
# `make verify-all-scenarios` must not leave another repository dirty under
# an operator who was only attesting a release.
CAPTURED="${TMP_DIR}/lab-order-service.json"
# Pretty-printed with sorted keys: the fixture is reviewed as a diff, and a
# one-line capture would make every refresh unreadable.
python3 -c '
import json, sys
json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=2, sort_keys=True)
open(sys.argv[2], "a").write("\n")
' "${PAYLOAD}" "${CAPTURED}"
ok "captured to ${CAPTURED} ($(wc -c < "${CAPTURED}" | tr -d ' ') bytes)"

if [ "${HUB_CONTRACT_INSTALL_FIXTURE:-no}" != "yes" ]; then
  ok "not installed: set HUB_CONTRACT_INSTALL_FIXTURE=yes to refresh ${FIXTURE_REL}"
  record "fixture captured" PASS "captured, not installed"
elif [ -d "${PLUGIN_REPO}" ]; then
  FIXTURE="${PLUGIN_REPO}/${FIXTURE_REL}"
  mkdir -p "$(dirname "${FIXTURE}")"
  cp "${CAPTURED}" "${FIXTURE}"
  ok "installed to ${FIXTURE_REL}, review the diff before committing it"
  record "fixture captured" PASS "installed to ${FIXTURE_REL}"
else
  fail "no plugin checkout at ${PLUGIN_REPO}; set PERF_SENTINEL_PLUGIN_REPO_PATH"
  record "fixture captured" FAIL "no plugin checkout"
fi

# === 4: the navigation anchor, and its absence, are recorded ===
step "4. the code_location gap is measured, not assumed"
ANCHORED="$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))
print(sum(1 for r in rows if (r.get("finding") or {}).get("code_location")))
' "${PAYLOAD}")"
if [ "${ANCHORED}" = "0" ]; then
  ok "0/${COUNT} findings carry a code_location, as expected from the Java agent"
  record "anchor gap measured" PASS "0 anchored, navigation not covered here"
else
  # Not a failure: an anchor appearing means the instrumentation improved and
  # the plugin's navigation contract becomes testable from a real capture.
  ok "${ANCHORED}/${COUNT} findings now carry a code_location"
  record "anchor gap measured" PASS "${ANCHORED} anchored, navigation now capturable"
fi

step "Report"
{
  echo "# ${SCENARIO}"
  echo
  echo "| sub-test | verdict | note |"
  echo "|---|---|---|"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"
step "Report written to ${REPORT}"

for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
