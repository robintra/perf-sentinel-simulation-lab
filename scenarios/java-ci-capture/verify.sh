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
  docker rm -f "${PG_CONTAINER}" "${COLLECTOR_CONTAINER}" jcc-gen >/dev/null 2>&1 || true
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
n = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    for rs in json.loads(line).get("resourceSpans", []):
        for ss in rs.get("scopeSpans", []):
            n += len(ss.get("spans", []))
print(n)
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

# ── D0: the recipe exactly as published ─────────────────────────────────────
# The POM's default endpoint IS the documented literal, so this leg runs the
# published configuration with no override at all.
DOC_ENDPOINT="$(grep -o 'http://localhost:[0-9]*' "${PROJECT}/pom.xml" | head -1)"
step "D0: the POM as published (endpoint ${DOC_ENDPOINT}, agent default protocol)"
D0_OUT="${TMP_DIR}/d0-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${D0_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- "${MVN}" $(mvn_args) > "${TMP_DIR}/d0-stdout.log" 2> "${TMP_DIR}/d0-stderr.log"
D0_RC=$?
D0_SPANS="$(span_count "${D0_OUT}")"
if [ "${D0_SPANS}" -gt 0 ]; then
  assert_pass "D0" "the published POM captured ${D0_SPANS} span(s)"
else
  PROTO_WARN="$(grep -ho "endpoint port is likely incorrect for protocol version \"[^\"]*\"" "${TMP_DIR}/d0-stderr.log" | head -1)"
  assert_fail "D0" "the published POM captured nothing (capture rc=${D0_RC}): $(grep -o 'Capture: [^.]*' "${TMP_DIR}/d0-stderr.log" | tail -1)${PROTO_WARN:+; agent warned: ${PROTO_WARN}}"
fi

# Everything below needs a configuration that actually exports. The documented
# endpoint targets 4317, capture's gRPC port, so the minimal correction is to
# state the protocol that endpoint implies instead of relying on the agent's
# default, which is http/protobuf in agent 2.x. Exported into the environment
# rather than added to the POM: the Failsafe fork inherits it, and the POM stays
# byte-for-byte the published recipe.

# ── D1 / D2 / D6: the nominal wrapped run ───────────────────────────────────
step "D1, D2, D6: capture --output ... -- mvn verify (protocol stated)"
CAP_OUT="${TMP_DIR}/capture-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${CAP_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- env OTEL_EXPORTER_OTLP_PROTOCOL=grpc "${MVN}" $(mvn_args) > "${TMP_DIR}/stdout.log" 2> "${TMP_DIR}/stderr.log"
CAP_RC=$?
REPORTS="${PROJECT}/target/failsafe-reports"

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
CAP_SPANS="$(span_count "${CAP_OUT}")"
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
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf "${MVN}" $(mvn_args "-Dlab.otel.endpoint=http://localhost:${COLLECTOR_PORT}") \
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
  -- env OTEL_EXPORTER_OTLP_PROTOCOL=grpc "${MVN}" $(mvn_args -Dlab.fail=1) \
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
OTEL_EXPORTER_OTLP_PROTOCOL=grpc "${MVN}" $(mvn_args) > "${TMP_DIR}/d5-mvn.log" 2>&1
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
step "F3: --output in a directory that does not exist"
rm -f "${TMP_DIR}/f3-witness"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${TMP_DIR}/no-such-dir/traces.json" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" \
  -- touch "${TMP_DIR}/f3-witness" > "${TMP_DIR}/f3-stdout.log" 2> "${TMP_DIR}/f3-stderr.log"
F3_RC=$?
if [ "${F3_RC}" = "1" ] && [ ! -f "${TMP_DIR}/f3-witness" ]; then
  assert_pass "F3" "exit 1 and the wrapped command never ran: $(grep -o 'Capture error: .*' "${TMP_DIR}/f3-stderr.log" | head -1 | cut -c1-80)"
else
  assert_fail "F3" "rc=${F3_RC} (want 1), witness present=$([ -f "${TMP_DIR}/f3-witness" ] && echo yes || echo no)"
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

# F2 — the handoff asks for a burst faster than the writer. What this leg
# actually measures is narrower and more useful: the counter that backs exit 2
# also counts requests refused BEFORE the queue, so a misconfigured exporter is
# reported as backpressure. A run that exits 2 saying "the exporter was faster
# than the writer" when nothing was ever queued is a wrong diagnosis, and it is
# the shape a user hits with OTEL_EXPORTER_OTLP_PROTOCOL=http/json.
step "F2: a request refused before the queue must not be reported as backpressure"
F2_OUT="${TMP_DIR}/f2-traces.json"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F2_OUT}" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" --grace-ms 500 \
  > "${TMP_DIR}/f2-stdout.log" 2> "${TMP_DIR}/f2-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_HTTP}" >/dev/null 2>&1 && break; sleep 0.5; done
F2_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://127.0.0.1:${CAPTURE_HTTP}/v1/traces" -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[]}')
kill -TERM "${CAPTURE_PID}" 2>/dev/null; wait "${CAPTURE_PID}" 2>/dev/null; F2_RC=$?
CAPTURE_PID=""
F2_MSG="$(grep -o 'Capture: .*' "${TMP_DIR}/f2-stderr.log" | tail -1)"
if echo "${F2_MSG}" | grep -qi "faster than the writer"; then
  assert_fail "F2" "a single ${F2_HTTP} at /v1/traces exits ${F2_RC} claiming backpressure: ${F2_MSG}"
else
  assert_pass "F2" "a ${F2_HTTP} at /v1/traces is not reported as backpressure (rc=${F2_RC}): ${F2_MSG:-no message}"
fi

step "F4: SIGTERM during a wrapped capture"
F4_OUT="${TMP_DIR}/f4-traces.json"
rm -f "${TMP_DIR}/f4-child-finished"
"${PERF_SENTINEL_LOCAL_BIN}" capture --output "${F4_OUT}" --listen-address 0.0.0.0 \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" --grace-ms 1000 \
  -- sh -c "sleep 90; touch ${TMP_DIR}/f4-child-finished" \
  > "${TMP_DIR}/f4-stdout.log" 2> "${TMP_DIR}/f4-stderr.log" &
CAPTURE_PID=$!
for _ in $(seq 1 30); do lsof -ti "tcp:${CAPTURE_GRPC}" >/dev/null 2>&1 && break; sleep 0.5; done
gen --traces 10 --workers 2
sleep 1
kill -TERM "${CAPTURE_PID}" 2>/dev/null; wait "${CAPTURE_PID}" 2>/dev/null; F4_RC=$?
CAPTURE_PID=""
sleep 2
# The grandchild is what a Failsafe fork would be: killing only the direct child
# leaves a test JVM holding its port and its database connection.
ORPHANS=$(pgrep -f "sleep 90" 2>/dev/null | wc -l | tr -d ' ')
F4_VALID=0
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${F4_OUT}" --format json >/dev/null 2>&1 && F4_VALID=1
if [ ! -f "${TMP_DIR}/f4-child-finished" ] && [ "${F4_VALID}" = "1" ] && [ "${ORPHANS}" = "0" ]; then
  assert_pass "F4" "child stopped, no orphan left, file still valid NDJSON (capture exited ${F4_RC})"
else
  pkill -f "sleep 90" 2>/dev/null
  assert_fail "F4" "orphaned grandchildren=${ORPHANS}, file re-readable=${F4_VALID}, child completed=$([ -f "${TMP_DIR}/f4-child-finished" ] && echo yes || echo no), capture rc=${F4_RC}"
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
