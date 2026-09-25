#!/usr/bin/env bash
# micrometer-http-client: a Spring Boot 4 service traced through Micrometer
# Observation, not the OTel agent, feeds perf-sentinel through every ingest
# format it can reach: OTLP (spring-boot-starter-opentelemetry, captured by
# `perf-sentinel capture`), Zipkin v2 JSON (the Brave bridge), Jaeger JSON (the
# OTLP capture replayed into a throwaway Jaeger) and the daemon's OTLP receiver.
#
# Micrometer tags a RestClient span `method` and `status` rather than
# `http.request.method` and `http.response.status_code`. perf-sentinel 0.25.1
# and older read every such call as a GET without a status, so a POST and a GET
# to one URL fused into one n_plus_one_http finding. 0.25.2 reads the two tags
# after both OTel conventions.
#
# Assertions (see README.md):
#   B0  both fixture profiles build.
#   O1  the OTLP capture holds 14 CLIENT spans shaped by Micrometer alone:
#       `method` and `status` present, no OTel HTTP method or status key.
#   O2  analyze splits n_plus_one_http into POST x6 and GET x7.
#   O3  embedded events: POST 201 x6, GET 200 x6, GET 404 x1, and the call
#       that got no response (status=CLIENT_ERROR) carries no status.
#   Z1-Z3, J1-J3  the same three on the Zipkin and Jaeger files.
#   D1  the daemon, fed by the app directly, reports the same two findings.
#   P1  each finding keeps one signature across the four paths.
#
# Self-contained: no cluster. Needs the local release binary, JDK 25, Maven,
# python3 and Docker (throwaway Jaeger only).
set -uo pipefail

SCENARIO="micrometer-http-client"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CENSUS="${SCRIPT_DIR}/fixtures/census.py"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
# 2.21.0 removed the v1 HTTP API (/api/traces) that Jaeger JSON comes from.
JAEGER_IMAGE="${JAEGER_IMAGE:-jaegertracing/jaeger:2.20.0}"
JAEGER_CONTAINER="mhc-jaeger"
CAPTURE_GRPC="${CAPTURE_GRPC:-15317}"
CAPTURE_HTTP="${CAPTURE_HTTP:-15318}"
JAEGER_OTLP="${JAEGER_OTLP:-15319}"
JAEGER_QUERY="${JAEGER_QUERY:-16687}"
DAEMON_HTTP="${DAEMON_HTTP:-15320}"
DAEMON_GRPC="${DAEMON_GRPC:-15321}"
ZIPKIN_PORT="${ZIPKIN_PORT:-19411}"

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
  docker rm -f "${JAEGER_CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release)"
for tool in java mvn python3 docker curl; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
step "binary under test: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
cp -R "${SCRIPT_DIR}/fixtures" "${TMP_DIR}/project"

# The two finding rows every path must produce (template, occurrences).
EXPECTED_FINDINGS=$'GET localhost/api/items/{id}\t7\nPOST localhost/api/items/{id}\t6'
EXPECTED_EVENTS=$'GET /api/unreachable\tNone\t1\nGET localhost/api/items/{id}\t200\t6\nGET localhost/api/items/{id}\t404\t1\nPOST localhost/api/items/{id}\t201\t6'

# check_file <leg prefix> <shape kind> <trace file>: the shape, findings and
# events legs on one trace file. Leaves the finding rows in <prefix>.findings.
check_file() {
  local p="$1" kind="$2" file="$3" got
  got="$(python3 "${CENSUS}" shape "${kind}" "${file}")"
  if [ "${got}" = "ok 14" ]; then
    assert_pass "${p}1" "14 CLIENT spans tagged method/status by Micrometer, no OTel HTTP key"
  else
    assert_fail "${p}1" "span shape: ${got}"
  fi

  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${file}" --format json > "${TMP_DIR}/${p}-analyze.json" 2> "${TMP_DIR}/${p}-analyze.err"
  python3 "${CENSUS}" findings "${TMP_DIR}/${p}-analyze.json" | sort > "${TMP_DIR}/${p}.findings"
  got="$(cut -f1,2 "${TMP_DIR}/${p}.findings")"
  if [ "${got}" = "${EXPECTED_FINDINGS}" ]; then
    assert_pass "${p}2" "n_plus_one_http split by verb: POST x6, GET x7"
  else
    assert_fail "${p}2" "n_plus_one_http rows: $(echo "${got}" | tr '\t\n' ' ;')"
  fi

  "${PERF_SENTINEL_LOCAL_BIN}" report --input "${file}" --output "${TMP_DIR}/${p}-report.html" > /dev/null 2>&1
  got="$(python3 "${CENSUS}" events "${TMP_DIR}/${p}-report.html")"
  if [ "${got}" = "${EXPECTED_EVENTS}" ]; then
    assert_pass "${p}3" "events: POST 201 x6, GET 200 x6, GET 404 x1, CLIENT_ERROR left without status"
  else
    assert_fail "${p}3" "events: $(echo "${got}" | tr '\t\n' ' ;')"
  fi
}

# =============================================================================
step "B0: build the otlp and zipkin profiles"
if (cd "${TMP_DIR}/project" && mvn -q -DskipTests package > "${TMP_DIR}/build-otlp.log" 2>&1 \
      && cp target/micrometer-http-client-1.0.0-SNAPSHOT.jar "${TMP_DIR}/app-otlp.jar" \
      && mvn -q -Pzipkin -P'!otlp' -DskipTests clean package > "${TMP_DIR}/build-zipkin.log" 2>&1 \
      && cp target/micrometer-http-client-1.0.0-SNAPSHOT.jar "${TMP_DIR}/app-zipkin.jar"); then
  assert_pass "B0" "both jars built"
else
  assert_fail "B0" "maven build failed, see ${TMP_DIR}/build-*.log"
  die "cannot go on without the fixture"
fi

# =============================================================================
step "O: spring-boot-starter-opentelemetry -> perf-sentinel capture"
"${PERF_SENTINEL_LOCAL_BIN}" capture -o "${TMP_DIR}/otlp.ndjson" \
  --listen-port-grpc "${CAPTURE_GRPC}" --listen-port-http "${CAPTURE_HTTP}" -- \
  java -jar "${TMP_DIR}/app-otlp.jar" \
  --management.opentelemetry.tracing.export.otlp.endpoint="http://127.0.0.1:${CAPTURE_HTTP}/v1/traces" \
  > "${TMP_DIR}/otlp-run.log" 2>&1 || die "capture run failed, see ${TMP_DIR}/otlp-run.log"
check_file O otlp "${TMP_DIR}/otlp.ndjson"

# =============================================================================
step "Z: Brave bridge -> Zipkin v2 JSON"
python3 "${SCRIPT_DIR}/fixtures/zipkin-sink.py" "${ZIPKIN_PORT}" "${TMP_DIR}/zipkin.json" &
BG_PIDS+=($!); disown "$!"
sleep 1
java -jar "${TMP_DIR}/app-zipkin.jar" \
  --management.tracing.export.zipkin.endpoint="http://127.0.0.1:${ZIPKIN_PORT}/api/v2/spans" \
  > "${TMP_DIR}/zipkin-run.log" 2>&1 || die "zipkin run failed, see ${TMP_DIR}/zipkin-run.log"
sleep 1
[ -s "${TMP_DIR}/zipkin.json" ] || die "the Zipkin sink received nothing"
check_file Z zipkin "${TMP_DIR}/zipkin.json"

# =============================================================================
step "J: the OTLP capture replayed into ${JAEGER_IMAGE} -> Jaeger JSON"
docker rm -f "${JAEGER_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${JAEGER_CONTAINER}" \
  -p "127.0.0.1:${JAEGER_OTLP}:4318" -p "127.0.0.1:${JAEGER_QUERY}:16686" \
  "${JAEGER_IMAGE}" > /dev/null || die "cannot start ${JAEGER_IMAGE}"
for _ in $(seq 60); do curl -sf "http://127.0.0.1:${JAEGER_QUERY}/api/services" > /dev/null && break; sleep 1; done
curl -sf -H 'Content-Type: application/json' --data-binary @"${TMP_DIR}/otlp.ndjson" \
  "http://127.0.0.1:${JAEGER_OTLP}/v1/traces" > /dev/null || die "replay into Jaeger refused"
for _ in $(seq 20); do
  curl -sf "http://127.0.0.1:${JAEGER_QUERY}/api/traces?service=micrometer-client&limit=5&lookback=2d" > "${TMP_DIR}/jaeger.json"
  python3 -c "import json,sys; sys.exit(0 if sum(len(t['spans']) for t in json.load(open('${TMP_DIR}/jaeger.json'))['data']) == 28 else 1)" 2>/dev/null && break
  sleep 1
done
check_file J jaeger "${TMP_DIR}/jaeger.json"

# =============================================================================
step "D: the app exports straight to the daemon's OTLP receiver"
printf '[daemon]\ntrace_ttl_ms = 1000\n' > "${TMP_DIR}/watch.toml"
"${PERF_SENTINEL_LOCAL_BIN}" watch -c "${TMP_DIR}/watch.toml" \
  --listen-port-http "${DAEMON_HTTP}" --listen-port-grpc "${DAEMON_GRPC}" > "${TMP_DIR}/watch.log" 2>&1 &
BG_PIDS+=($!); disown "$!"
for _ in $(seq 40); do curl -sf "http://127.0.0.1:${DAEMON_HTTP}/health" > /dev/null && break; sleep 0.5; done
java -jar "${TMP_DIR}/app-otlp.jar" \
  --management.opentelemetry.tracing.export.otlp.endpoint="http://127.0.0.1:${DAEMON_HTTP}/v1/traces" \
  > "${TMP_DIR}/daemon-run.log" 2>&1 || die "daemon run failed, see ${TMP_DIR}/daemon-run.log"
for _ in $(seq 20); do
  curl -sf "http://127.0.0.1:${DAEMON_HTTP}/api/findings" > "${TMP_DIR}/D-findings.json"
  python3 "${CENSUS}" findings "${TMP_DIR}/D-findings.json" | sort > "${TMP_DIR}/D.findings"
  [ "$(wc -l < "${TMP_DIR}/D.findings")" -ge 2 ] && break
  sleep 1
done
got="$(cut -f1,2 "${TMP_DIR}/D.findings")"
if [ "${got}" = "${EXPECTED_FINDINGS}" ]; then
  assert_pass "D1" "daemon ${BIN_VERSION}: n_plus_one_http POST x6, GET x7"
else
  assert_fail "D1" "daemon n_plus_one_http rows: $(echo "${got}" | tr '\t\n' ' ;')"
fi

# =============================================================================
step "P1: one signature per finding across the four paths"
distinct="$(cat "${TMP_DIR}"/{O,Z,J,D}.findings | cut -f1,3 | sort -u | wc -l | tr -d ' ')"
if [ "${distinct}" = "2" ]; then
  assert_pass "P1" "OTLP, Zipkin, Jaeger and daemon agree on both signatures"
else
  assert_fail "P1" "${distinct} distinct (template, signature) pairs, want 2"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "A Spring Boot 4 service traced through Micrometer Observation, read by"
  echo "perf-sentinel ${BIN_VERSION} over OTLP, Zipkin, Jaeger and the daemon."
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
