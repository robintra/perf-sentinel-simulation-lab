#!/usr/bin/env bash
# java-ci-capture: run the upstream Java CI recipe end to end, the `perf-sentinel
# capture` shape documented in docs/INSTRUMENTATION.md, "CI integration tests
# (Maven Failsafe)", Option 1.
#
# History: the recipe first named `otlp_file` + OTEL_EXPORTER_OTLP_FILE_PATH,
# which exist nowhere in OpenTelemetry; then `experimental-otlp/stdout`, which a
# forked Failsafe cannot hand back, because the agent captures the fork's command
# channel in premain (this scenario is what measured that). `capture` receives
# OTLP over the network instead, so the fork stays untouched.
#
# Assertions (see README.md):
#   D0  the POM exactly as published produces a non-empty capture.
#   D1  `mvn verify` runs normally, fork included, no Corrupted channel, no
#       .dumpstream.
#   D2  Maven's own logs reach the console untouched and perf-sentinel writes
#       nothing to stdout.
#   D3  analyze on the captured file finds n_plus_one_sql with the SAME census as
#       the same run exported to a Collector `file` exporter.
#   D4  a failing test surfaces as Maven's own non-zero exit code.
#   D5  the service form (capture &, then SIGTERM) yields the same counters.
#   D6  the last export batch is not lost: the file carries every span.
#   F1  --max-file-size exceeded: exit 2, message naming the flag, file valid.
#   F2  a request refused before the queue is named unusable, not backpressure.
#   F3  --output under a parent that is a regular file: exit 1, wrapped command
#       never runs. (A missing directory used to belong here; 0.9.25 creates it,
#       so the legitimate refusal needs a path a mkdir cannot fix.)
#   F4  SIGTERM stops the whole command tree, probed by PID.
#   F5  --listen-address 0.0.0.0 reached from a neighbouring container.
#   F6  genuine writer saturation is reported as backpressure, and only as that.
#   F7  --output target/traces.json on a CLEAN workspace: the directory is
#       created and the suite runs, instead of the run failing before it starts.
#   F8  the wrapped command deleting target/ mid-capture fails the run, instead
#       of reporting a span count for a file that no longer exists.
#
# Self-contained: no cluster. Needs the local release binary, a JDK, Maven and
# Docker (throwaway PostgreSQL, plus a throwaway Collector for the D3 reference).
set -uo pipefail

SCENARIO="java-ci-capture"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
COLLECTOR_IMAGE="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.155.0}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
PG_CONTAINER="jcc-postgres"
COLLECTOR_CONTAINER="jcc-collector"
PG_PORT="${PG_PORT:-15442}"
COLLECTOR_PORT="${COLLECTOR_PORT:-14418}"
# capture's own defaults, which are also what the documented endpoint targets.
CAPTURE_GRPC="${CAPTURE_GRPC:-4317}"
CAPTURE_HTTP="${CAPTURE_HTTP:-4318}"
# N+1 width. The trace carries ITEMS JDBC spans plus one SERVER parent.
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

CAPTURE_PID=""
cleanup() {
  [ -n "${CAPTURE_PID}" ] && kill -TERM "${CAPTURE_PID}" 2>/dev/null || true
  docker rm -f "${PG_CONTAINER}" "${COLLECTOR_CONTAINER}" jcc-gen jcc-gen1 jcc-gen2 jcc-gen3 jcc-gen4 jcc-gen5 jcc-gen6 >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
"${PERF_SENTINEL_LOCAL_BIN}" capture --help >/dev/null 2>&1 \
  || die "this binary has no 'capture' subcommand — rebuild from a branch that has it"
command -v java >/dev/null 2>&1 || die "no JDK on PATH — this scenario runs the documented Maven recipe for real"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — needed for the throwaway PostgreSQL and Collector"
if command -v mvn >/dev/null 2>&1; then
  MVN="mvn"
elif [ -x "${SCRIPT_DIR}/../../services/mvnw" ]; then
  MVN="${SCRIPT_DIR}/../../services/mvnw"
else
  die "no mvn on PATH and no services/mvnw wrapper"
fi
for p in "${CAPTURE_GRPC}" "${CAPTURE_HTTP}"; do
  lsof -ti "tcp:${p}" >/dev/null 2>&1 \
    && die "port ${p} is already in use; capture needs it (the documented endpoint targets it)"
done

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

# Built in TMP_DIR so no target/ ever appears in the repository.
cp -R "${SCRIPT_DIR}/fixtures" "${PROJECT}"
DB_URL="jdbc:postgresql://localhost:${PG_PORT}/labdb?user=lab&password=lab"

# `-B` but NOT `-q`: D2 asserts Maven's own logs reach the console.
mvn_args() {
  printf '%s\n' -B -f "${PROJECT}/pom.xml" verify \
    "-Dlab.db.url=${DB_URL}" "-Dlab.items=${ITEMS}" "$@"
}

analyze_json() {  # $1 = input ; $2 = output ; rc passthrough (--ci trips on findings)
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --ci --input "$1" --format json \
    > "$2" 2> "${TMP_DIR}/analyze-err.txt"
}

census() {  # per-finding identity + occurrence count, comparable across runs
  [ -s "$1" ] || { echo "<no findings file>"; return; }
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

span_count() {  # spans actually present in the NDJSON capture
  [ -s "$1" ] || { echo 0; return; }
  python3 -c '
import json, sys
from collections import Counter
# Count the spans of the REQUEST trace, not every span in the file. The test
# creates its own schema before opening the request span, and those statements
# are instrumented too — they just land in their own single-span traces. Taking
# the largest trace is what "every span of the request arrived" actually means.
traces = Counter()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    for rs in json.loads(line).get("resourceSpans", []):
        for ss in rs.get("scopeSpans", []):
            for sp in ss.get("spans", []):
                traces[sp.get("traceId", "")] += 1
print(max(traces.values()) if traces else 0)
' "$1"
}

occurrences_of() {
  [ -s "$1" ] || { echo 0; return; }
  python3 -c '
import json, sys
occ = [f.get("pattern", {}).get("occurrences")
       for f in json.load(open(sys.argv[1]))["findings"] if f["type"] == sys.argv[2]]
print(max(occ) if occ else 0)
' "$1" "$2"
}

# ── D0 / D1 / D2 / D6: the recipe exactly as published ──────────────────────
# The POM's endpoint and protocol are the documented literals, so this run
# exercises the published configuration with no override at all.
DOC_ENDPOINT="$(grep -o 'http://localhost:[0-9]*' "${PROJECT}/pom.xml" | head -1)"
DOC_PROTOCOL="$(sed -n 's#.*<lab.otel.protocol>\(.*\)</lab.otel.protocol>.*#\1#p' "${PROJECT}/pom.xml" | head -1)"
step "D0-D2, D6: capture -- mvn verify, POM as published (${DOC_ENDPOINT}, protocol ${DOC_PROTOCOL})"
CAP_OUT="${TMP_DIR}/capture-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${CAP_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- "${MVN}" $(mvn_args) > "${TMP_DIR}/stdout.log" 2> "${TMP_DIR}/stderr.log"
CAP_RC=$?
REPORTS="${PROJECT}/target/failsafe-reports"
CAP_SPANS="$(span_count "${CAP_OUT}")"

# D0 — the published recipe exports at all. Round 2 measured 0 spans here: the
# endpoint named :4317 while the agent defaulted to http/protobuf.
if [ "${CAP_SPANS}" -gt 0 ]; then
  assert_pass "D0" "the published POM captured ${CAP_SPANS} span(s) with protocol ${DOC_PROTOCOL} on ${DOC_ENDPOINT}"
else
  PROTO_WARN="$(grep -ho "endpoint port is likely incorrect for protocol version \"[^\"]*\"" "${TMP_DIR}/stderr.log" | head -1)"
  assert_fail "D0" "the published POM captured nothing (capture rc=${CAP_RC}): $(grep -o 'Capture: [^.]*' "${TMP_DIR}/stderr.log" | tail -1)${PROTO_WARN:+; agent warned: ${PROTO_WARN}}"
fi

# D1 — the fork survives: this is the whole point of moving off stdout.
CORRUPT=$(grep -rci "Corrupted channel\|Corrupted STDOUT" "${REPORTS}" "${TMP_DIR}/stdout.log" "${TMP_DIR}/stderr.log" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
DUMPSTREAMS=$(ls "${REPORTS}"/*.dumpstream 2>/dev/null | wc -l | tr -d ' ')
TESTS_RUN="$(grep -ho "Tests run: [0-9]*, Failures: [0-9]*, Errors: [0-9]*" "${TMP_DIR}/stdout.log" | tail -1)"
if [ "${CAP_RC}" = "0" ] && [ "${CORRUPT}" = "0" ] && [ "${DUMPSTREAMS}" = "0" ] && [ -n "${TESTS_RUN}" ]; then
  assert_pass "D1" "mvn verify green through the wrapper (${TESTS_RUN}), no channel corruption, no .dumpstream"
else
  assert_fail "D1" "capture rc=${CAP_RC}, corrupted=${CORRUPT}, dumpstreams=${DUMPSTREAMS}, tests=[${TESTS_RUN:-none}]"
fi

# D2 — stdout belongs to the wrapped command.
MAVEN_MARKERS=$(grep -cE "^\[INFO\]|BUILD SUCCESS" "${TMP_DIR}/stdout.log")
PS_ON_STDOUT=$(grep -ciE "^Capture:|perf-sentinel" "${TMP_DIR}/stdout.log")
if [ "${MAVEN_MARKERS}" -gt 0 ] && [ "${PS_ON_STDOUT}" = "0" ]; then
  assert_pass "D2" "Maven's own log on stdout (${MAVEN_MARKERS} lines), nothing from perf-sentinel there"
else
  assert_fail "D2" "maven lines=${MAVEN_MARKERS}, perf-sentinel lines on stdout=${PS_ON_STDOUT}: $(grep -iE '^Capture:|perf-sentinel' "${TMP_DIR}/stdout.log" | head -1)"
fi

# D6 — no batch lost at JVM shutdown: ITEMS JDBC spans plus one SERVER parent.
EXPECTED_SPANS=$((ITEMS + 1))
if [ "${CAP_SPANS}" = "${EXPECTED_SPANS}" ]; then
  assert_pass "D6" "${CAP_SPANS} spans captured = ${ITEMS} JDBC + 1 SERVER, nothing lost at shutdown"
else
  assert_fail "D6" "captured ${CAP_SPANS} spans, expected ${EXPECTED_SPANS} (a short fall points at --grace-ms, default 2000, not at the ingest)"
fi

# ── the D3 reference: same test, Collector file exporter ────────────────────
step "D3 reference: the same IT exported to a Collector file exporter"
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
"${MVN}" $(mvn_args "-Dlab.otel.endpoint=http://localhost:${COLLECTOR_PORT}" -Dlab.otel.protocol=http/protobuf) \
  > "${TMP_DIR}/mvn-collector.log" 2>&1 || die "the reference run failed: $(tail -20 "${TMP_DIR}/mvn-collector.log")"
REF_DUMP="${TMP_DIR}/dump/otlp-dump.ndjson"
for _ in $(seq 1 30); do [ -s "${REF_DUMP}" ] && break; sleep 1; done
[ -s "${REF_DUMP}" ] || die "the Collector wrote no NDJSON — no reference to compare against"

analyze_json "${REF_DUMP}" "${TMP_DIR}/ref-findings.json"
REF_CENSUS="$(census "${TMP_DIR}/ref-findings.json")"
echo "${REF_CENSUS}" | grep -q 'n_plus_one_sql' \
  || die "the Collector reference itself has no n_plus_one_sql — the payload is wrong, not the capture"

# D3 — parity, not mere presence.
step "D3: capture census == Collector census"
analyze_json "${CAP_OUT}" "${TMP_DIR}/cap-findings.json"
CAP_CENSUS="$(census "${TMP_DIR}/cap-findings.json")"
CAP_OCC="$(occurrences_of "${TMP_DIR}/cap-findings.json" n_plus_one_sql)"
REF_OCC="$(occurrences_of "${TMP_DIR}/ref-findings.json" n_plus_one_sql)"
if [ "${CAP_OCC}" = "${ITEMS}" ] && [ "${CAP_CENSUS}" = "${REF_CENSUS}" ]; then
  assert_pass "D3" "n_plus_one_sql at ${CAP_OCC} occurrences, census identical to the Collector reference"
else
  assert_fail "D3" "capture: ${CAP_OCC} occurrences / Collector reference: ${REF_OCC} (expected ${ITEMS}); census equal: $([ "${CAP_CENSUS}" = "${REF_CENSUS}" ] && echo yes || echo no)"
fi

# ── D4: a failing test stays a failing job ──────────────────────────────────
step "D4: a failing test surfaces as Maven's exit code through the wrapper"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${TMP_DIR}/d4-traces.json" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- "${MVN}" $(mvn_args -Dlab.fail=1) \
  > "${TMP_DIR}/d4-stdout.log" 2> "${TMP_DIR}/d4-stderr.log"
D4_RC=$?
MVN_FAILED=$(grep -c "BUILD FAILURE" "${TMP_DIR}/d4-stdout.log")
if [ "${D4_RC}" != "0" ] && [ "${MVN_FAILED}" -gt 0 ]; then
  assert_pass "D4" "test failure propagated: Maven BUILD FAILURE, capture exited ${D4_RC}"
else
  assert_fail "D4" "capture rc=${D4_RC} with BUILD FAILURE=${MVN_FAILED} — a failing suite must not exit 0"
fi

# ── D5: the service form ────────────────────────────────────────────────────
# The shape the original Jenkins pipeline would use: a capture running beside a
# test step the pipeline owns and cannot prefix.
step "D5: service form — capture &, mvn verify, kill -TERM"
D5_OUT="${TMP_DIR}/d5-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${D5_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  > "${TMP_DIR}/d5-capture-stdout.log" 2> "${TMP_DIR}/d5-capture-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do
  lsof -ti "tcp:${CAPTURE_GRPC}" >/dev/null 2>&1 && break
  sleep 0.5
done
"${MVN}" $(mvn_args) > "${TMP_DIR}/d5-mvn.log" 2>&1
D5_MVN_RC=$?
kill -TERM "${CAPTURE_PID}" 2>/dev/null
wait "${CAPTURE_PID}" 2>/dev/null
D5_RC=$?
CAPTURE_PID=""
analyze_json "${D5_OUT}" "${TMP_DIR}/d5-findings.json"
D5_CENSUS="$(census "${TMP_DIR}/d5-findings.json")"
D5_OCC="$(occurrences_of "${TMP_DIR}/d5-findings.json" n_plus_one_sql)"
if [ "${D5_MVN_RC}" = "0" ] && [ "${D5_CENSUS}" = "${CAP_CENSUS}" ] && [ "${D5_OCC}" = "${ITEMS}" ]; then
  assert_pass "D5" "SIGTERM form: same census as the wrapped form, ${D5_OCC} occurrences (capture exited ${D5_RC})"
else
  assert_fail "D5" "mvn rc=${D5_MVN_RC}, capture rc=${D5_RC}, occurrences=${D5_OCC} (wrapped form: ${CAP_OCC})"
fi

# ── F: the capture exit-code contract ───────────────────────────────────────
# Every line of it exists to stop a run that lost spans from reporting success,
# so these are negative tests: the pass condition is a non-zero code plus a
# message that names the real cause.
GEN_IMAGE="${GEN_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest}"
gen() {  # telemetrygen from a neighbouring container, reaching the host listener
  docker run --rm --add-host=host.docker.internal:host-gateway "${GEN_IMAGE}" \
    traces --otlp-endpoint "host.docker.internal:${CAPTURE_GRPC}" --otlp-insecure "$@" \
    >/dev/null 2>&1
}

# F3 first: it needs no traffic at all.
#
# A missing directory used to land here. Since 0.9.25 it is created (F7), so the
# refusal has to be probed with a path that creating a directory cannot fix: a
# parent that is a regular file. The refusal itself must stay, and it must stay
# BEFORE the wrapped command starts — a capture that cannot listen must never
# leave a test suite running detached.
step "F3: --output under a parent that is a regular file"
rm -f "${TMP_DIR}/f3-witness"
: > "${TMP_DIR}/f3-blocker"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${TMP_DIR}/f3-blocker/traces.json" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- touch "${TMP_DIR}/f3-witness" > "${TMP_DIR}/f3-stdout.log" 2> "${TMP_DIR}/f3-stderr.log"
F3_RC=$?
if [ "${F3_RC}" = "1" ] && [ ! -f "${TMP_DIR}/f3-witness" ]; then
  assert_pass "F3" "exit 1 and the wrapped command never ran: $(grep -o 'Capture error: .*' "${TMP_DIR}/f3-stderr.log" | head -1 | cut -c1-90)"
else
  assert_fail "F3" "rc=${F3_RC} (want 1), witness present=$([ -f "${TMP_DIR}/f3-witness" ] && echo yes || echo no)"
fi

# F7 — the defect this scenario reported from a real Jenkins controller: on a
# clean CI workspace `target/` does not exist yet, because Maven is what creates
# it and Maven is the command being wrapped. 0.9.24 refused to start, so the
# integration suite never ran at all. A fresh copy of the fixtures is used
# rather than PROJECT, which already has a target/ from D0.
step "F7: --output target/traces.json on a clean workspace (no target/ yet)"
F7_PROJECT="${TMP_DIR}/clean-workspace"
rm -rf "${F7_PROJECT}"
cp -R "${SCRIPT_DIR}/fixtures" "${F7_PROJECT}"
F7_OUT="${F7_PROJECT}/target/traces.json"
[ ! -e "${F7_PROJECT}/target" ] || die "F7 setup: the copied workspace already has a target/"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F7_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- "${MVN}" -B -f "${F7_PROJECT}/pom.xml" verify \
     "-Dlab.db.url=${DB_URL}" "-Dlab.items=${ITEMS}" \
  > "${TMP_DIR}/f7-stdout.log" 2> "${TMP_DIR}/f7-stderr.log"
F7_RC=$?
F7_SPANS="$(span_count "${F7_OUT}")"
F7_TESTS="$(ls "${F7_PROJECT}/target/failsafe-reports"/*.txt 2>/dev/null | wc -l | tr -d ' ')"
if [ "${F7_RC}" = "0" ] && [ "${F7_SPANS}" -gt 0 ] && [ "${F7_TESTS}" -gt 0 ]; then
  assert_pass "F7" "the missing target/ was created, the suite ran (${F7_TESTS} failsafe report(s)) and ${F7_SPANS} spans were captured"
else
  assert_fail "F7" "rc=${F7_RC}, spans=${F7_SPANS}, failsafe reports=${F7_TESTS}: $(grep -o 'Capture error: .*' "${TMP_DIR}/f7-stderr.log" | head -1 | cut -c1-90)"
fi

# F8 — the other half of the same fix. `mvn clean` deletes target/ AFTER capture
# opened the file in it; on Unix the writer keeps filling an unlinked inode, so
# every counter stays real while the path holds nothing. 0.9.24 printed a span
# count and exited 0, sending the next step to a file that never existed.
# Reusing F7's workspace on purpose: target/ is now populated, which is what a
# `mvn clean` actually finds.
step "F8: the wrapped command deletes target/ while the capture is writing"
F8_OUT="${F7_PROJECT}/target/traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F8_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- "${MVN}" -B -f "${F7_PROJECT}/pom.xml" clean verify \
     "-Dlab.db.url=${DB_URL}" "-Dlab.items=${ITEMS}" \
  > "${TMP_DIR}/f8-stdout.log" 2> "${TMP_DIR}/f8-stderr.log"
F8_RC=$?
F8_MSG="$(grep -o 'Capture error: .*' "${TMP_DIR}/f8-stderr.log" | head -1)"
F8_PRESENT="$([ -f "${F8_OUT}" ] && echo yes || echo no)"
if [ "${F8_RC}" != "0" ] && [ "${F8_PRESENT}" = "no" ] \
   && printf '%s' "${F8_MSG}" | grep -qi "removed while the capture was writing"; then
  assert_pass "F8" "exit ${F8_RC} and the cause is named rather than a span count reported: $(printf '%s' "${F8_MSG}" | cut -c1-95)"
else
  assert_fail "F8" "rc=${F8_RC} (want non-zero), trace file present=${F8_PRESENT}, message: ${F8_MSG:-<none>}"
fi

step "F5: --listen-address 0.0.0.0 reached from a neighbouring container"
F5_OUT="${TMP_DIR}/f5-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F5_OUT}" --listen-address 0.0.0.0 \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" --grace-ms 1000 \
  > "${TMP_DIR}/f5-stdout.log" 2> "${TMP_DIR}/f5-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_GRPC}" >/dev/null 2>&1 && break; sleep 0.5; done
gen --traces 10 --workers 2
sleep 1
kill -TERM "${CAPTURE_PID}" 2>/dev/null; wait "${CAPTURE_PID}" 2>/dev/null; F5_RC=$?
CAPTURE_PID=""
F5_SPANS="$(span_count "${F5_OUT}")"
if [ "${F5_RC}" = "0" ] && [ "${F5_SPANS}" -gt 0 ]; then
  assert_pass "F5" "container-to-host export captured ${F5_SPANS} spans, exit ${F5_RC}"
else
  assert_fail "F5" "rc=${F5_RC}, spans=${F5_SPANS} — the documented cross-container topology did not deliver"
fi

step "F1: --max-file-size 1 on a run that produces more"
F1_OUT="${TMP_DIR}/f1-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F1_OUT}" --listen-address 0.0.0.0 \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  --max-file-size 1 --grace-ms 1000 \
  > "${TMP_DIR}/f1-stdout.log" 2> "${TMP_DIR}/f1-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_GRPC}" >/dev/null 2>&1 && break; sleep 0.5; done
docker rm -f jcc-gen >/dev/null 2>&1 || true
docker run -d --name jcc-gen --add-host=host.docker.internal:host-gateway "${GEN_IMAGE}" \
  traces --otlp-endpoint "host.docker.internal:${CAPTURE_GRPC}" --otlp-insecure \
  --duration 300s --workers 20 --child-spans 25 >/dev/null 2>&1
# Throughput from a container to the host is machine-dependent, so wait for the
# cap rather than for a fixed time, and SKIP instead of failing if it never
# arrives — a slow host must not read as a broken size guard.
F1_CAPPED=0
for _ in $(seq 1 "${F1_WAIT_S:-240}"); do
  grep -qi "size limit reached" "${TMP_DIR}/f1-stderr.log" && { F1_CAPPED=1; break; }
  sleep 1
done
docker rm -f jcc-gen >/dev/null 2>&1 || true
kill -TERM "${CAPTURE_PID}" 2>/dev/null; wait "${CAPTURE_PID}" 2>/dev/null; F1_RC=$?
CAPTURE_PID=""
if [ "${F1_CAPPED}" = "0" ]; then
  record "F1" "SKIP — the generator never pushed past 1 MiB on this host (raise F1_WAIT_S)"
  color_red "    skip: cap never reached in ${F1_WAIT_S:-240}s"
elif [ "${F1_RC}" = "2" ] && grep -qi "max-file-size" "${TMP_DIR}/f1-stderr.log"; then
  assert_pass "F1" "exit 2, message names --max-file-size, file kept valid at $(wc -c < "${F1_OUT}" | tr -d ' ') bytes"
else
  assert_fail "F1" "rc=${F1_RC} (want 2), message: $(grep -o 'Capture: .*' "${TMP_DIR}/f1-stderr.log" | tail -1 | cut -c1-90)"
fi

# F2 — the two rejection causes must be told apart. Round 2 found them sharing
# one counter, so a misconfigured exporter was reported as writer backpressure.
# Both causes still exit 2 (the file is incomplete either way); what must differ
# is the diagnosis the user acts on.
step "F2: a request refused before the queue is named as unusable, not as backpressure"
f2_probe() {  # $1 = content-type ; $2 = body ; echoes "<http> <rc> <message>"
  local out="${TMP_DIR}/f2-traces.json" cp code rc
  rm -f "${out}"
  "${PERF_SENTINEL_LOCAL_BIN}" capture --output "${out}" \
    --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" --grace-ms 500 \
    > "${TMP_DIR}/f2-stdout.log" 2> "${TMP_DIR}/f2-stderr.log" &
  cp=$!
  for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_HTTP}" >/dev/null 2>&1 && break; sleep 0.5; done
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://127.0.0.1:${CAPTURE_HTTP}/v1/traces" -H "Content-Type: $1" -d "$2")
  kill -TERM "${cp}" 2>/dev/null; wait "${cp}" 2>/dev/null; rc=$?
  printf '%s %s %s' "${code}" "${rc}" "$(grep -o 'Capture: .*' "${TMP_DIR}/f2-stderr.log" | tail -1)"
}
F2_FAILURES=""
for probe in "application/json|{\"resourceSpans\":[]}|415" \
             "application/x-protobuf|not-protobuf-at-all|400"; do
  CT="${probe%%|*}"; REST="${probe#*|}"; BODY="${REST%|*}"; WANT="${REST##*|}"
  RESULT="$(f2_probe "${CT}" "${BODY}")"
  GOT_CODE="${RESULT%% *}"; REST2="${RESULT#* }"; GOT_RC="${REST2%% *}"; MSG="${REST2#* }"
  if [ "${GOT_RC}" = "2" ] \
     && echo "${MSG}" | grep -q "refused as unusable" \
     && echo "${MSG}" | grep -q "OTEL_EXPORTER_OTLP_PROTOCOL" \
     && ! echo "${MSG}" | grep -qi "faster than the writer"; then
    ok "${CT} -> http ${GOT_CODE}, exit ${GOT_RC}, named as unusable"
  else
    F2_FAILURES="${F2_FAILURES} [${CT}: http=${GOT_CODE} (want ${WANT}) rc=${GOT_RC} msg=${MSG}]"
  fi
done
if [ -z "${F2_FAILURES}" ]; then
  assert_pass "F2" "415 and 400 both exit 2 as 'refused as unusable' naming OTEL_EXPORTER_OTLP_PROTOCOL, never as backpressure"
else
  assert_fail "F2" "${F2_FAILURES}"
fi

step "F4: SIGTERM stops the whole command tree"
F4_OUT="${TMP_DIR}/f4-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F4_OUT}" --listen-address 0.0.0.0 \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" --grace-ms 1000 \
  -- sh -c "sleep 90" > "${TMP_DIR}/f4-stdout.log" 2> "${TMP_DIR}/f4-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_GRPC}" >/dev/null 2>&1 && break; sleep 0.5; done
gen --traces 10 --workers 2
# The grandchild is what a Failsafe fork would be. Probed by PID: a witness file
# written after the sleep is absent whether the process lives or not, so it
# proves nothing — the round-2 leg had exactly that hole.
GRANDCHILD="$(pgrep -f '^sleep 90' | head -1)"
[ -n "${GRANDCHILD}" ] || die "F4: no grandchild to probe, the wrapped command never started"
kill -TERM "${CAPTURE_PID}" 2>/dev/null; wait "${CAPTURE_PID}" 2>/dev/null; F4_RC=$?
CAPTURE_PID=""
# SIGKILL follows SIGTERM after 5s upstream, so allow for that before probing.
for _ in $(seq 1 14); do kill -0 "${GRANDCHILD}" 2>/dev/null || break; sleep 1; done
ALIVE=0; kill -0 "${GRANDCHILD}" 2>/dev/null && ALIVE=1
F4_VALID=0
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${F4_OUT}" --format json >/dev/null 2>&1 && F4_VALID=1
if [ "${ALIVE}" = "0" ] && [ "${F4_VALID}" = "1" ]; then
  assert_pass "F4" "grandchild ${GRANDCHILD} stopped with the group, file still valid NDJSON (capture exited ${F4_RC})"
else
  kill -9 "${GRANDCHILD}" 2>/dev/null
  assert_fail "F4" "grandchild ${GRANDCHILD} alive=${ALIVE} (orphaned, reparented to init), file re-readable=${F4_VALID}, capture rc=${F4_RC}"
fi

# F6 — genuine writer saturation, measurable only now that the two rejection
# causes are separate counters. The exporter cannot be made fast enough from a
# container (~1 req/s), so the writer is blocked instead: the output is a FIFO
# whose reader holds it open and reads nothing, which stalls the writer while the
# 256-slot channel fills. The reader then drains so capture can finish.
step "F6: writer saturation is reported as backpressure, and only as that"
F6_PIPE="${TMP_DIR}/f6.pipe"
rm -f "${F6_PIPE}"; mkfifo "${F6_PIPE}"
sh -c "exec 3< '${F6_PIPE}'; sleep ${F6_BLOCK_S:-100}; cat <&3 > /dev/null" >/dev/null 2>&1 &
F6_READER=$!
sleep 1
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F6_PIPE}" --listen-address 0.0.0.0 \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" --grace-ms 500 \
  > "${TMP_DIR}/f6-stdout.log" 2> "${TMP_DIR}/f6-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_GRPC}" >/dev/null 2>&1 && break; sleep 0.5; done
for n in 1 2 3 4 5 6; do
  docker run -d --name "jcc-gen${n}" --add-host=host.docker.internal:host-gateway "${GEN_IMAGE}" \
    traces --otlp-endpoint "host.docker.internal:${CAPTURE_GRPC}" --otlp-insecure \
    --duration 90s --workers 20 --child-spans 10 >/dev/null 2>&1
done
# The rejection counts are a summary printed at exit, not a stream, so there is
# nothing to poll for: hold the writer blocked for the whole generator window,
# then let the reader drain and read the summary capture leaves behind.
sleep "${F6_BLOCK_S:-100}"
for n in 1 2 3 4 5 6; do docker rm -f "jcc-gen${n}" >/dev/null 2>&1 || true; done
sleep 12   # the reader is draining now; let the writer catch up so capture can exit
kill -TERM "${CAPTURE_PID}" 2>/dev/null; wait "${CAPTURE_PID}" 2>/dev/null; F6_RC=$?
CAPTURE_PID=""
kill "${F6_READER}" 2>/dev/null
F6_MSG="$(grep -o 'Capture: .*' "${TMP_DIR}/f6-stderr.log" | tail -2 | tr '\n' ' ')"
F6_SATURATED=0
echo "${F6_MSG}" | grep -qi "could not be queued" && F6_SATURATED=1
if [ "${F6_SATURATED}" = "0" ]; then
  record "F6" "SKIP — the generators never filled the 256-slot channel on this host (raise F6_BLOCK_S/F6_WAIT_S)"
  color_red "    skip: saturation not reached"
elif [ "${F6_RC}" = "2" ] \
     && echo "${F6_MSG}" | grep -qi "faster than the writer" \
     && ! echo "${F6_MSG}" | grep -qi "refused as unusable"; then
  assert_pass "F6" "exit 2 as backpressure only, no unusable rejection: $(grep -o '[0-9]* requests could not be queued' "${TMP_DIR}/f6-stderr.log" | tail -1)"
else
  assert_fail "F6" "rc=${F6_RC} (want 2), message: ${F6_MSG}"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The upstream Java CI recipe (Maven Failsafe + \`perf-sentinel capture\`)"
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
