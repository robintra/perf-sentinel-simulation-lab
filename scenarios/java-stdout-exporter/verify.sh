#!/usr/bin/env bash
# java-stdout-exporter: run the upstream Java CI recipe end to end.
#
# Java has no OTLP file exporter. The documented path (upstream
# docs/INSTRUMENTATION.md, "CI integration tests (Maven Failsafe, stdout
# exporter)") is therefore: attach the agent to the Failsafe fork, export with
# `experimental-otlp/stdout`, let `redirectTestOutputToFile` park the JVM's
# stdout under target/failsafe-reports/<Class>-output.txt, then
#   grep -h '^{"resourceSpans"' target/failsafe-reports/*-output.txt > traces.json
# and feed that to `analyze --ci --input`. Before 0.9.24 this recipe named
# `otlp_file` + `OTEL_EXPORTER_OTLP_FILE_PATH`, which exist nowhere in
# OpenTelemetry — an external user followed it on Jenkins and got no traces at
# all. Nothing in the lab executed it, so nothing caught it. This does.
#
# Assertions (see README.md):
#   B1  the agent autoconfigures on `experimental-otlp/stdout`: no unrecognized
#       value, no silently inactive exporter.
#   B2  the OTLP JSON lands on stdout UNPREFIXED — every line carrying
#       resourceSpans starts with it, so the documented grep matches them all.
#   B3  redirectTestOutputToFile parks those lines in
#       target/failsafe-reports/<Class>-output.txt.
#   B4  analyze on the grepped file finds the planted N+1, with the SAME census
#       as the same test exported over the network to a collector file exporter.
#   B5  always_on keeps every repetition: the finding counts N occurrences for
#       N queries, not a sample.
#
# Self-contained: no cluster. Needs the local release binary, a JDK, Maven and
# Docker (throwaway PostgreSQL, plus a throwaway collector for the parity leg).
set -uo pipefail

SCENARIO="java-stdout-exporter"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.155.0}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
PG_CONTAINER="jse-postgres"
COLLECTOR_CONTAINER="jse-collector"
PG_PORT="${PG_PORT:-15442}"
COLLECTOR_PORT="${COLLECTOR_PORT:-14418}"
# N+1 width. Also the expected occurrence count in B5.
ITEMS="${ITEMS:-15}"
PROJECT="${TMP_DIR}/project"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}/dump"
chmod 777 "${TMP_DIR}/dump"   # the contrib collector runs as UID 10001

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

cleanup() {
  docker rm -f "${PG_CONTAINER}" "${COLLECTOR_CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
command -v java >/dev/null 2>&1 || die "no JDK on PATH — this scenario runs the documented Maven recipe for real"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — needed for the throwaway PostgreSQL and collector"
if command -v mvn >/dev/null 2>&1; then
  MVN="mvn"
elif [ -x "${SCRIPT_DIR}/../../services/mvnw" ]; then
  MVN="${SCRIPT_DIR}/../../services/mvnw"
else
  die "no mvn on PATH and no services/mvnw wrapper"
fi
[ -f "${SCRIPT_DIR}/fixtures/pom.xml" ] || die "missing fixtures/pom.xml"

# ── throwaway PostgreSQL ────────────────────────────────────────────────────
step "Throwaway PostgreSQL on :${PG_PORT}"
docker rm -f "${PG_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${PG_CONTAINER}" \
  -e POSTGRES_USER=lab -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=labdb \
  -p "${PG_PORT}:5432" "${POSTGRES_IMAGE}" >/dev/null || die "postgres start failed"
PG_READY=0
for _ in $(seq 1 60); do
  docker exec "${PG_CONTAINER}" pg_isready -U lab -d labdb >/dev/null 2>&1 && { PG_READY=1; break; }
  sleep 1
done
[ "${PG_READY}" = "1" ] || die "postgres never became ready: $(docker logs "${PG_CONTAINER}" 2>&1 | tail -3)"
docker exec "${PG_CONTAINER}" psql -U lab -d labdb -q -c \
  "CREATE TABLE lab_order_items (id serial PRIMARY KEY, order_id int NOT NULL);
   INSERT INTO lab_order_items (order_id) SELECT g % 20 FROM generate_series(1, 200) g;" \
  >/dev/null 2>&1 || die "seeding lab_order_items failed"
ok "lab_order_items seeded"

# The project is built in TMP_DIR so target/ never lands in the repo.
cp -R "${SCRIPT_DIR}/fixtures" "${PROJECT}"
DB_URL="jdbc:postgresql://localhost:${PG_PORT}/labdb?user=lab&password=lab"

run_its() {  # $1 = OTEL_TRACES_EXPORTER value ; $2 = OTLP endpoint (may be empty)
  "${MVN}" -B -q -f "${PROJECT}/pom.xml" verify \
    -Dlab.otel.traces.exporter="$1" \
    -Dlab.otel.endpoint="$2" \
    -Dlab.db.url="${DB_URL}" \
    -Dlab.items="${ITEMS}"
}

analyze_json() {  # $1 = input ; $2 = output json ; rc passthrough (--ci trips on findings)
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --ci --input "$1" --format json \
    > "$2" 2> "${TMP_DIR}/analyze-err.txt"
}

census() {  # per-finding identity + occurrence count, run-to-run comparable
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
rows = sorted(
    (f.get("signature", ""), f.get("type", ""), f.get("severity", ""),
     f.get("pattern", {}).get("occurrences"), f.get("pattern", {}).get("template"))
    for f in d.get("findings", []))
print(json.dumps(rows))
' "$1"
}

# ── run 1: the documented recipe, verbatim ──────────────────────────────────
step "1. mvn verify with OTEL_TRACES_EXPORTER=experimental-otlp/stdout"
MVN_RC=0
run_its "experimental-otlp/stdout" "" > "${TMP_DIR}/mvn-stdout.log" 2>&1 || MVN_RC=$?
REPORTS="${PROJECT}/target/failsafe-reports"
[ "${MVN_RC}" = "0" ] || die "mvn verify failed (rc=${MVN_RC}): $(tail -20 "${TMP_DIR}/mvn-stdout.log")"
ok "mvn verify green"

# B1 — autoconfiguration ONLY. A rejected exporter name aborts the agent with
# "Unrecognized value"; a silently inactive one emits nothing anywhere. Counted
# across every Failsafe artefact, not just -output.txt, so that "the agent
# works" stays separable from "the output reaches the documented file" — which
# is exactly where this recipe breaks.
step "B1: agent autoconfigures on experimental-otlp/stdout"
OUTPUT_FILES=$(ls "${REPORTS}"/*-output.txt 2>/dev/null | wc -l | tr -d ' ')
AGENT_ERR="$(grep -rhiE "Unrecognized value|Unsupported.*exporter|Failed to (install|initialize)" \
  "${TMP_DIR}/mvn-stdout.log" "${REPORTS}" 2>/dev/null | head -3)"
EMITTED=$(grep -rho '{"resourceSpans"' "${REPORTS}" "${TMP_DIR}/mvn-stdout.log" 2>/dev/null | wc -l | tr -d ' ')
if [ -z "${AGENT_ERR}" ] && [ "${EMITTED}" -gt 0 ]; then
  assert_pass "B1" "no autoconfiguration error, exporter emitted ${EMITTED} OTLP batch(es)"
else
  assert_fail "B1" "emitted=${EMITTED}, agent error: ${AGENT_ERR:-none}"
fi

# B2 — every emitted batch must be reachable by the documented grep, which is
# anchored on ^. Two ways to lose them: a logger prefix (that is why the docs
# rule out `logging-otlp`), or Surefire deciding the fork wrote to its command
# channel and diverting the bytes into a .dumpstream file.
step "B2: every emitted batch is reachable by the documented grep"
CAPTURED=$(cat "${REPORTS}"/*-output.txt 2>/dev/null | grep -c '^{"resourceSpans"')
if [ "${EMITTED}" -gt 0 ] && [ "${CAPTURED}" = "${EMITTED}" ]; then
  assert_pass "B2" "${CAPTURED}/${EMITTED} batches start exactly with {\"resourceSpans\""
else
  DIVERTED="$(grep -rhoiE "Corrupted (channel|STDOUT) by directly writing to native stream[^.]*" \
    "${REPORTS}" 2>/dev/null | head -1)"
  STRAY="$(grep -rh '{"resourceSpans"' "${REPORTS}" 2>/dev/null | grep -v '^{"resourceSpans"' | head -1 | cut -c1-100)"
  assert_fail "B2" "only ${CAPTURED}/${EMITTED} reachable; diverted as [${DIVERTED:-none}]; a stray line starts: ${STRAY:-none}"
fi

# B3 — the redirect itself: the documented glob reads per-class output files,
# so batches landing anywhere else (build console, .dumpstream) are lost.
step "B3: redirectTestOutputToFile parks the batches under target/failsafe-reports"
IT_OUTPUT="${REPORTS}/com.perfsim.labit.OrderItemsIT-output.txt"
if [ -s "${IT_OUTPUT}" ] && grep -q '^{"resourceSpans"' "${IT_OUTPUT}"; then
  assert_pass "B3" "$(basename "${IT_OUTPUT}") holds the OTLP batches (${OUTPUT_FILES} output file(s) total)"
else
  ELSEWHERE="$(grep -rl '{"resourceSpans"' "${REPORTS}" 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
  assert_fail "B3" "no per-class output file carries the OTLP JSON; it is in: ${ELSEWHERE:-nowhere}"
fi

step "Documented capture: grep -h '^{\"resourceSpans\"' ... > traces.json"
grep -h '^{"resourceSpans"' "${REPORTS}"/*-output.txt > "${TMP_DIR}/traces.json" 2>/dev/null
STDOUT_RC=0; analyze_json "${TMP_DIR}/traces.json" "${TMP_DIR}/stdout-findings.json" || STDOUT_RC=$?
# --ci exits non-zero when the quality gate trips, which is the point here: the
# test plants a real N+1. Only an ingest failure leaves no JSON behind. Not a
# die(): B4 and B5 are the assertions that say what the recipe cost, so they
# have to reach the report rather than be cut short by an early exit.
STDOUT_CENSUS=""
if [ -s "${TMP_DIR}/stdout-findings.json" ]; then
  STDOUT_CENSUS="$(census "${TMP_DIR}/stdout-findings.json")"
  ok "captured $(wc -l < "${TMP_DIR}/traces.json" | tr -d ' ') line(s), analyze rc=${STDOUT_RC}"
else
  color_red "    the documented capture yielded nothing analyzable (rc=${STDOUT_RC}): $(tail -1 "${TMP_DIR}/analyze-err.txt")"
fi

# ── run 2: same test, network OTLP, for the parity comparison ───────────────
step "2. Same IT over the network: OTLP -> collector file exporter"
docker rm -f "${COLLECTOR_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${COLLECTOR_CONTAINER}" \
  -p "${COLLECTOR_PORT}:4318" \
  -v "${SCRIPT_DIR}/collector.yaml:/cfg/config.yaml:ro" \
  -v "${TMP_DIR}/dump:/var/otel" \
  "${COLLECTOR_IMAGE}" --config=/cfg/config.yaml >/dev/null || die "collector start failed"
COL_READY=0
for _ in $(seq 1 30); do
  docker logs "${COLLECTOR_CONTAINER}" 2>&1 | grep -qi "Everything is ready" && { COL_READY=1; break; }
  docker ps --format '{{.Names}}' | grep -q "${COLLECTOR_CONTAINER}" \
    || die "collector crashed: $(docker logs "${COLLECTOR_CONTAINER}" 2>&1 | tail -3)"
  sleep 1
done
[ "${COL_READY}" = "1" ] || die "collector never became ready"

MVN_RC=0
run_its "otlp" "http://localhost:${COLLECTOR_PORT}" > "${TMP_DIR}/mvn-otlp.log" 2>&1 || MVN_RC=$?
[ "${MVN_RC}" = "0" ] || die "mvn verify (otlp run) failed (rc=${MVN_RC}): $(tail -20 "${TMP_DIR}/mvn-otlp.log")"
DUMP="${TMP_DIR}/dump/otlp-dump.ndjson"
for _ in $(seq 1 30); do
  [ -s "${DUMP}" ] && break
  sleep 1
done
[ -s "${DUMP}" ] || die "collector wrote no NDJSON — the network run exported nothing"
NET_RC=0; analyze_json "${DUMP}" "${TMP_DIR}/net-findings.json" || NET_RC=$?
[ -s "${TMP_DIR}/net-findings.json" ] \
  || die "analyze produced no JSON from the collector dump (rc=${NET_RC}): $(tail -3 "${TMP_DIR}/analyze-err.txt")"
NET_CENSUS="$(census "${TMP_DIR}/net-findings.json")"

finding_types() {  # "" when the file is missing, so the messages stay readable
  [ -s "$1" ] || { echo ""; return; }
  python3 -c 'import json,sys; print(" ".join(sorted({f["type"] for f in json.load(open(sys.argv[1]))["findings"]})))' "$1"
}
occurrences_of() {  # max occurrence count for a finding type, 0 when absent
  [ -s "$1" ] || { echo 0; return; }
  python3 -c '
import json, sys
occ = [f.get("pattern", {}).get("occurrences")
       for f in json.load(open(sys.argv[1]))["findings"] if f["type"] == sys.argv[2]]
print(max(occ) if occ else 0)
' "$1" "$2"
}

# B4 — a file that ingests cleanly but carries half the spans is a failure, so
# the assertion is parity with the network path, not merely "a finding exists".
# The network run doubles as the control: if it finds nothing either, the fault
# is the test payload, not the capture.
step "B4: findings from the captured stdout == findings from the network export"
STDOUT_TYPES="$(finding_types "${TMP_DIR}/stdout-findings.json")"
NET_TYPES="$(finding_types "${TMP_DIR}/net-findings.json")"
echo "${NET_TYPES}" | grep -q 'n_plus_one_sql' \
  || die "the network run found no n_plus_one_sql either [${NET_TYPES}] — the payload is wrong, not the capture"
if echo "${STDOUT_TYPES}" | grep -q 'n_plus_one_sql' && [ "${STDOUT_CENSUS}" = "${NET_CENSUS}" ]; then
  assert_pass "B4" "n_plus_one_sql present [${STDOUT_TYPES}], census identical to the network export"
else
  assert_fail "B4" "network export sees [${NET_TYPES}], documented capture sees [${STDOUT_TYPES:-nothing}]"
fi

# B5 — always_on is what keeps the repetitions the detector counts.
step "B5: always_on keeps all ${ITEMS} repetitions"
OCC="$(occurrences_of "${TMP_DIR}/stdout-findings.json" n_plus_one_sql)"
NET_OCC="$(occurrences_of "${TMP_DIR}/net-findings.json" n_plus_one_sql)"
if [ "${OCC}" = "${ITEMS}" ]; then
  assert_pass "B5" "n_plus_one_sql counts ${OCC} occurrences for ${ITEMS} queries"
else
  assert_fail "B5" "expected ${ITEMS} occurrences, got ${OCC} from the documented capture (the same run over the network counts ${NET_OCC}, so sampling and the BatchSpanProcessor flush are not the cause)"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The upstream Java CI recipe (Maven Failsafe + \`experimental-otlp/stdout\`)"
  echo "run end to end, from the agent to \`analyze --ci\`."
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
  color_green "PASS — report at ${REPORT}"
else
  die "FAIL (${FAILS} assertion(s)) — report at ${REPORT}"
fi
