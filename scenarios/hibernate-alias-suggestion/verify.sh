#!/usr/bin/env bash
# hibernate-alias-suggestion: which suggested fix a Java finding gets when no
# span names Hibernate. A Spring Boot 4 + Spring Data JPA app runs five loops
# (lazy loads, a JdbcTemplate SELECT, a derived query, a bulk JPQL UPDATE,
# RestClient GETs) under the OTel Java agent, under the agent with its
# Hibernate and Spring Data instrumentation off, and under the Micrometer
# bridge of spring-boot-starter-opentelemetry.
#
# perf-sentinel 0.25.2 and older gave the Java generic fix to a SELECT that
# Hibernate generated whenever no span of the finding named Hibernate, which
# is the case of every lazy load under the default agent, and no fix at all to
# a finding traced through Micrometer, whose only scope is
# `org.springframework.boot`. 0.25.3 reads Hibernate's table aliases (`b1_0`)
# on a SELECT, and that scope as Java.
#
# Assertions (see README.md):
#   B0  both fixture profiles build.
#   A0  agent: the lazy-load finding names no Hibernate or Spring Data scope
#       and no code location.
#   A1  agent: lazy loads -> java_jpa.
#   A2  agent: hand-written JdbcTemplate SELECT -> java_generic.
#   A3  agent: derived query and bulk UPDATE, under a Hibernate span -> java_jpa.
#   C0  bare agent: no finding names Hibernate or Spring Data, and the derived
#       query and the UPDATE open with Hibernate's SQL comment.
#   C1  bare agent: lazy loads -> java_jpa.
#   C2  bare agent: commented derived SELECT -> java_jpa.
#   C3  bare agent: commented bulk UPDATE -> java_generic.
#   C4  bare agent: JdbcTemplate SELECT -> java_generic.
#   M0  micrometer: every span under org.springframework.boot, no
#       code.namespace, no database span.
#   M1  micrometer: n_plus_one_http -> java_generic.
#   D1  daemon, fed by the agent directly: lazy loads -> java_jpa.
#   P1  agent file and daemon agree on every finding signature.
#
# Self-contained: no cluster. Needs the local release binary, JDK 25, Maven
# and python3.
set -uo pipefail

SCENARIO="hibernate-alias-suggestion"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CENSUS="${SCRIPT_DIR}/fixtures/census.py"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
CAPTURE_GRPC="${CAPTURE_GRPC:-15417}"
CAPTURE_HTTP="${CAPTURE_HTTP:-15418}"
DAEMON_HTTP="${DAEMON_HTTP:-15420}"
DAEMON_GRPC="${DAEMON_GRPC:-15421}"

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

BG_PIDS=()
cleanup() {
  for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release)"
for tool in java mvn python3 curl; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
step "binary under test: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
cp -R "${SCRIPT_DIR}/fixtures" "${TMP_DIR}/project"

AGENT_ARGS=(-Dotel.service.name=hibernate-alias -Dotel.exporter.otlp.protocol=http/protobuf
  -Dotel.metrics.exporter=none -Dotel.logs.exporter=none)
BARE_ARGS=(-Dotel.instrumentation.hibernate.enabled=false -Dotel.instrumentation.spring-data.enabled=false)

# row <census file> <loop>: that loop's census line, empty when absent.
row() { awk -F'\t' -v l="$2" '$1 == l' "$1"; }
# col <census file> <loop> <column>
col() { row "$1" "$2" | cut -f"$3"; }

# expect_fix <id> <census file> <loop> <framework> <label>
expect_fix() {
  local got
  got="$(col "$2" "$3" 2)"
  if [ "${got}" = "$4" ]; then
    assert_pass "$1" "$5 -> $4"
  else
    assert_fail "$1" "$5 -> ${got:-no finding}, want $4"
  fi
}

# analyze_to <census file> <trace file>
analyze_to() {
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "$2" --format json > "$1.json" 2> "$1.err"
  python3 "${CENSUS}" findings "$1.json" > "$1"
}

# capture_agent <out ndjson> <extra JVM flags...> -- <app args...>
capture_agent() {
  local out="$1"; shift
  local jvm=() app=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do jvm+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  app=("$@")
  "${PERF_SENTINEL_LOCAL_BIN}" capture -o "${out}" \
    --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" -- \
    java -javaagent:"${TMP_DIR}/agent.jar" "${AGENT_ARGS[@]}" ${jvm[@]+"${jvm[@]}"} \
    -Dotel.exporter.otlp.endpoint="http://127.0.0.1:${CAPTURE_HTTP}" \
    -jar "${TMP_DIR}/app-agent.jar" ${app[@]+"${app[@]}"}
}

# =============================================================================
step "B0: build the default and micrometer profiles"
if (cd "${TMP_DIR}/project" && mvn -q -DskipTests package > "${TMP_DIR}/build-agent.log" 2>&1 \
      && cp target/hibernate-alias-suggestion-1.0.0-SNAPSHOT.jar "${TMP_DIR}/app-agent.jar" \
      && cp target/opentelemetry-javaagent.jar "${TMP_DIR}/agent.jar" \
      && mvn -q -Pmicrometer -DskipTests clean package > "${TMP_DIR}/build-micrometer.log" 2>&1 \
      && cp target/hibernate-alias-suggestion-1.0.0-SNAPSHOT.jar "${TMP_DIR}/app-micrometer.jar"); then
  assert_pass "B0" "both jars built, agent copied"
else
  assert_fail "B0" "maven build failed, see ${TMP_DIR}/build-*.log"
  die "cannot go on without the fixture"
fi

# =============================================================================
step "A: OTel Java agent, default instrumentation"
capture_agent "${TMP_DIR}/agent.ndjson" > "${TMP_DIR}/agent-run.log" 2>&1 \
  || die "agent run failed, see ${TMP_DIR}/agent-run.log"
A="${TMP_DIR}/A.census"
analyze_to "${A}" "${TMP_DIR}/agent.ndjson"
if [ "$(col "${A}" lazy 4)$(col "${A}" lazy 5)" = "nono" ]; then
  assert_pass "A0" "lazy-load finding names no Hibernate or Spring Data scope and no code location"
else
  assert_fail "A0" "lazy-load finding: $(row "${A}" lazy | tr '\t' ' ')"
fi
expect_fix A1 "${A}" lazy java_jpa "lazy loads, no Hibernate span"
expect_fix A2 "${A}" jdbc java_generic "hand-written JdbcTemplate SELECT"
got="$(col "${A}" derived 2) $(col "${A}" update 2)"
if [ "${got}" = "java_jpa java_jpa" ]; then
  assert_pass "A3" "derived query and bulk UPDATE under a Hibernate span -> java_jpa"
else
  assert_fail "A3" "derived query and bulk UPDATE -> ${got}, want java_jpa java_jpa"
fi

# =============================================================================
step "C: agent without Hibernate and Spring Data instrumentation, SQL comments on"
capture_agent "${TMP_DIR}/bare.ndjson" "${BARE_ARGS[@]}" -- \
  --spring.jpa.properties.hibernate.use_sql_comments=true > "${TMP_DIR}/bare-run.log" 2>&1 \
  || die "bare agent run failed, see ${TMP_DIR}/bare-run.log"
C="${TMP_DIR}/C.census"
analyze_to "${C}" "${TMP_DIR}/bare.ndjson"
named="$(cut -f4 "${C}" | sort -u | tr '\n' ' ')"
comments="$(col "${C}" derived 6) $(col "${C}" update 6)"
if [ "${named}" = "no " ] && [ "${comments}" = "yes yes" ]; then
  assert_pass "C0" "no finding names Hibernate, derived query and UPDATE open with /* ... */"
else
  assert_fail "C0" "hibernate scope column: ${named}, comment on derived/update: ${comments}"
fi
expect_fix C1 "${C}" lazy java_jpa "lazy loads"
expect_fix C2 "${C}" derived java_jpa "commented derived SELECT"
expect_fix C3 "${C}" update java_generic "commented bulk UPDATE"
expect_fix C4 "${C}" jdbc java_generic "hand-written JdbcTemplate SELECT"

# =============================================================================
step "M: spring-boot-starter-opentelemetry, no agent"
"${PERF_SENTINEL_LOCAL_BIN}" capture -o "${TMP_DIR}/micrometer.ndjson" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" -- \
  java -jar "${TMP_DIR}/app-micrometer.jar" \
  --management.opentelemetry.tracing.export.otlp.endpoint="http://127.0.0.1:${CAPTURE_HTTP}/v1/traces" \
  > "${TMP_DIR}/micrometer-run.log" 2>&1 || die "micrometer run failed, see ${TMP_DIR}/micrometer-run.log"
got="$(python3 "${CENSUS}" micrometer "${TMP_DIR}/micrometer.ndjson")"
if [ "${got#ok }" != "${got}" ]; then
  assert_pass "M0" "${got#ok } spans, all under org.springframework.boot, no code.namespace, no db span"
else
  assert_fail "M0" "span shape: ${got}"
fi
M="${TMP_DIR}/M.census"
analyze_to "${M}" "${TMP_DIR}/micrometer.ndjson"
expect_fix M1 "${M}" http java_generic "n_plus_one_http through Micrometer"

# =============================================================================
step "D: the agent exports straight to the daemon's OTLP receiver"
printf '[daemon]\ntrace_ttl_ms = 1000\n' > "${TMP_DIR}/watch.toml"
"${PERF_SENTINEL_LOCAL_BIN}" watch -c "${TMP_DIR}/watch.toml" \
  --listen-port-http "${DAEMON_HTTP}" --listen-port-grpc "${DAEMON_GRPC}" > "${TMP_DIR}/watch.log" 2>&1 &
BG_PIDS+=($!); disown "$!"
for _ in $(seq 40); do curl -sf "http://127.0.0.1:${DAEMON_HTTP}/health" > /dev/null && break; sleep 0.5; done
java -javaagent:"${TMP_DIR}/agent.jar" "${AGENT_ARGS[@]}" \
  -Dotel.exporter.otlp.endpoint="http://127.0.0.1:${DAEMON_HTTP}" \
  -jar "${TMP_DIR}/app-agent.jar" > "${TMP_DIR}/daemon-run.log" 2>&1 \
  || die "daemon run failed, see ${TMP_DIR}/daemon-run.log"
D="${TMP_DIR}/D.census"
for _ in $(seq 20); do
  curl -sf "http://127.0.0.1:${DAEMON_HTTP}/api/findings" > "${D}.json"
  python3 "${CENSUS}" findings "${D}.json" > "${D}"
  [ "$(wc -l < "${D}")" -ge "$(wc -l < "${A}")" ] && break
  sleep 1
done
expect_fix D1 "${D}" lazy java_jpa "daemon ${BIN_VERSION}: lazy loads"

# =============================================================================
step "P1: agent file and daemon agree on every signature"
if [ -s "${A}" ] && diff <(cut -f1,3 "${A}") <(cut -f1,3 "${D}") > "${TMP_DIR}/P1.diff"; then
  assert_pass "P1" "$(wc -l < "${A}" | tr -d ' ') findings, same signatures from the file and the daemon"
else
  assert_fail "P1" "signatures differ, see ${TMP_DIR}/P1.diff"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The suggested fix of Java findings no span names Hibernate for, read by"
  echo "perf-sentinel ${BIN_VERSION} under the OTel agent, the agent without its"
  echo "Hibernate instrumentation, Micrometer and the daemon."
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
