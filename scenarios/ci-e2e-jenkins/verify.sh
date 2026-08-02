#!/usr/bin/env bash
# ci-e2e-jenkins: the documented Java CI recipe run inside a REAL Jenkins, all
# the way to whether the published dashboard actually renders in a browser.
#
# Every lab scenario before the ci-e2e-* family stopped at "the HTML file is
# larger than 1024 bytes". That is what let a user hit a report that renders as
# a logo and a set of empty column headers, with nothing in the build log. The
# cause is not perf-sentinel: Jenkins serves build artifacts through
# DirectoryBrowserSupport under a strict Content-Security-Policy, the report
# packs its CSS and its ~4500 lines of JavaScript inline, and a <meta> CSP
# intersects an HTTP header CSP rather than overriding it.
#
# Assertions (see README.md):
#   J0  the documented one-liner works on a CLEAN workspace, as any CI job has
#   J1  the job runs the documented recipe and capture writes a non-empty file
#   J2  analyze finds the planted n_plus_one_sql with the expected occurrences
#   J3  report.html is produced and published by Jenkins
#   J4  what the dashboard does when fetched THROUGH JENKINS under its default
#       CSP — an observation, not a contract: today it is blank, and if that
#       ever changes the limitation was lifted and the docs need updating
#   J5  with the documented Script Console remedy applied, it RENDERS
#   J7  the documented future fix (CSS and JS in sibling files) would NOT help
#   J8  the blocked page carries the 0.9.25 #ps-no-js notice explaining why it is
#       blank, and that notice is gone once the script runs
#
# J6 (Resource Root URL, option A of docs/CI.md) is deliberately not covered:
# it needs a second origin with its own hostname, and the CSP behaviour is
# already established by J4 and J5. See README.md.
#
# Self-contained: no cluster. Needs Docker, curl, python3 and Chrome.
set -uo pipefail

SCENARIO="ci-e2e-jenkins"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_CHECK="${SCRIPT_DIR}/../ci-e2e-common/render-check.sh"
JAVA_FIXTURES="${SCRIPT_DIR}/../java-ci-capture/fixtures"

JENKINS_IMAGE="${JENKINS_IMAGE:-perf-sentinel-lab-jenkins:2.568.1}"
# Where the perf-sentinel binary baked into the controller comes from. Defaults
# to the published release; a pre-release validation points it at a locally
# built image, the same override the other two ci-e2e scenarios take.
PERF_SENTINEL_IMAGE="${PERF_SENTINEL_IMAGE:-ghcr.io/robintra/perf-sentinel:0.9.24}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18.4-alpine}"
NETWORK="jce2e-net"
JENKINS_CONTAINER="jce2e-jenkins"
PG_CONTAINER="jce2e-postgres"
JENKINS_PORT="${JENKINS_PORT:-18080}"
JOB="perf-sentinel-e2e"
ITEMS=15
BUILD_TIMEOUT_S="${BUILD_TIMEOUT_S:-900}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

FAILS=0
declare -a SUMMARY
record() { SUMMARY+=("$1|$2"); }
assert_pass() { ok "$2"; record "$1" "PASS — $2"; }
assert_fail() { color_red "    FAIL: $2"; FAILS=$((FAILS + 1)); record "$1" "FAIL — $2"; }

cleanup() {
  docker rm -f "${JENKINS_CONTAINER}" "${PG_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — this scenario runs a real Jenkins"
[ -x "${RENDER_CHECK}" ] || die "missing ${RENDER_CHECK}"
[ -f "${JAVA_FIXTURES}/pom.xml" ] || die "missing the Maven fixture at ${JAVA_FIXTURES}"
JENKINS_URL="http://127.0.0.1:${JENKINS_PORT}"
lsof -ti "tcp:${JENKINS_PORT}" >/dev/null 2>&1 && die "port ${JENKINS_PORT} already in use"

cleanup
docker network create "${NETWORK}" >/dev/null 2>&1 || die "cannot create the docker network"

# ── PostgreSQL for the integration test ─────────────────────────────────────
step "Throwaway PostgreSQL on the ${NETWORK} network"
docker run -d --name "${PG_CONTAINER}" --network "${NETWORK}" \
  -e POSTGRES_USER=lab -e POSTGRES_PASSWORD=lab -e POSTGRES_DB=labdb \
  "${POSTGRES_IMAGE}" >/dev/null || die "postgres start failed"
PG_READY=0
for _ in $(seq 1 60); do
  docker exec "${PG_CONTAINER}" pg_isready -U lab -d labdb >/dev/null 2>&1 && { PG_READY=1; break; }
  sleep 1
done
[ "${PG_READY}" = "1" ] || die "postgres never became ready"
docker exec "${PG_CONTAINER}" psql -U lab -d labdb -q -c \
  "CREATE TABLE lab_order_items (id serial PRIMARY KEY, order_id int NOT NULL);
   INSERT INTO lab_order_items (order_id) SELECT g % 20 FROM generate_series(1, 200) g;" \
  >/dev/null 2>&1 || die "seeding lab_order_items failed"
ok "lab_order_items seeded"

# ── a real Jenkins controller ───────────────────────────────────────────────
# Copied in at build time rather than committed twice: one Maven project, one
# place to change it. The docker build context has to contain it, hence the copy.
rm -rf "${SCRIPT_DIR}/fixtures/project"
cp -R "${JAVA_FIXTURES}" "${SCRIPT_DIR}/fixtures/project"
rm -rf "${SCRIPT_DIR}/fixtures/project/target"

step "Build the Jenkins image (Maven + perf-sentinel from ${PERF_SENTINEL_IMAGE} + the job)"
docker build -q --build-arg "PERF_SENTINEL_IMAGE=${PERF_SENTINEL_IMAGE}" \
  -t "${JENKINS_IMAGE}" "${SCRIPT_DIR}/fixtures" > "${TMP_DIR}/image-build.log" 2>&1 \
  || die "jenkins image build failed: $(tail -5 "${TMP_DIR}/image-build.log")"
ok "${JENKINS_IMAGE} built"

step "Start Jenkins on ${JENKINS_URL}"
docker run -d --name "${JENKINS_CONTAINER}" --network "${NETWORK}" \
  -p "${JENKINS_PORT}:8080" \
  -e "LAB_PG_HOST=${PG_CONTAINER}" \
  "${JENKINS_IMAGE}" >/dev/null || die "jenkins start failed"
JENKINS_READY=0
for _ in $(seq 1 120); do
  curl -fsS -o /dev/null "${JENKINS_URL}/login" 2>/dev/null && { JENKINS_READY=1; break; }
  docker ps --format '{{.Names}}' | grep -q "${JENKINS_CONTAINER}" \
    || die "jenkins died on boot: $(docker logs "${JENKINS_CONTAINER}" 2>&1 | tail -5)"
  sleep 2
done
[ "${JENKINS_READY}" = "1" ] || die "jenkins never answered: $(docker logs "${JENKINS_CONTAINER}" 2>&1 | tail -5)"
ok "jenkins up ($(curl -sS -o /dev/null -w '%{http_code}' "${JENKINS_URL}/login"))"


# Jenkins enforces CSRF on POSTs even with an unsecured authorization strategy.
# The crumb is bound to the HTTP SESSION, so the crumb request and the POST must
# share a cookie jar — fetching a crumb with a bare curl and posting with
# another one yields a crumb issued for a different session, and a 403.
JENKINS_COOKIES="${TMP_DIR}/jenkins-cookies.txt"
jenkins_post() {  # $1 = path ; remaining args passed to curl
  local path="$1"; shift
  local crumb
  crumb="$(curl -fsS -c "${JENKINS_COOKIES}" -b "${JENKINS_COOKIES}" \
    "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])' 2>/dev/null)"
  if [ -n "${crumb}" ]; then
    curl -fsS -X POST -c "${JENKINS_COOKIES}" -b "${JENKINS_COOKIES}" \
      -H "${crumb}" "$@" "${JENKINS_URL}${path}"
  else
    curl -fsS -X POST -c "${JENKINS_COOKIES}" -b "${JENKINS_COOKIES}" \
      "$@" "${JENKINS_URL}${path}"
  fi
}

# ── run the job ─────────────────────────────────────────────────────────────
step "Trigger ${JOB} and wait for it (Maven resolves from scratch, allow time)"
curl -fsS -o /dev/null "${JENKINS_URL}/job/${JOB}/api/json" 2>/dev/null \
  || die "the ${JOB} job was not seeded — check /usr/share/jenkins/ref/jobs in the image"
jenkins_post "/job/${JOB}/build" >/dev/null 2>"${TMP_DIR}/trigger.err" \
  || die "cannot trigger the job: $(tail -2 "${TMP_DIR}/trigger.err")"
BUILD_DONE=0
for _ in $(seq 1 $((BUILD_TIMEOUT_S / 5))); do
  BUILDING="$(curl -fsS "${JENKINS_URL}/job/${JOB}/lastBuild/api/json" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("building"))' 2>/dev/null)"
  [ "${BUILDING}" = "False" ] && { BUILD_DONE=1; break; }
  sleep 5
done
[ "${BUILD_DONE}" = "1" ] || die "the build never finished within ${BUILD_TIMEOUT_S}s"
BUILD_RESULT="$(curl -fsS "${JENKINS_URL}/job/${JOB}/lastBuild/api/json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result"))')"
curl -fsS "${JENKINS_URL}/job/${JOB}/lastBuild/consoleText" > "${TMP_DIR}/console.txt" 2>/dev/null

ART="${JENKINS_URL}/job/${JOB}/lastBuild/artifact"

# J0 — the documented invocation is `capture --output target/traces.json --
# mvn verify`, and docs/ci-templates/jenkinsfile.groovy sets
# PERF_SENTINEL_TRACES to that same path. A CI workspace starts clean, so
# target/ does not exist yet: Maven is what creates it, and Maven has not run.
# Probed with the released binary inside the real controller, on a fresh dir.
step "J0: the documented one-liner on a clean workspace"
J0_OUT="$(docker exec "${JENKINS_CONTAINER}" sh -c \
  'cd "$(mktemp -d)" && perf-sentinel capture --output target/traces.json -- echo WRAPPED_COMMAND_RAN 2>&1; echo "rc=$?"' 2>&1)"
J0_RC="$(printf '%s' "${J0_OUT}" | sed -n 's/.*rc=\([0-9]*\).*/\1/p' | tail -1)"
if [ "${J0_RC}" = "0" ]; then
  assert_pass "J0" "the documented one-liner runs on a clean workspace"
else
  RAN="no"
  printf '%s' "${J0_OUT}" | grep -q WRAPPED_COMMAND_RAN && RAN="yes"
  assert_fail "J0" "the documented one-liner fails on a clean workspace (rc=${J0_RC}, wrapped command ran: ${RAN}): $(printf '%s' "${J0_OUT}" | grep -o 'Capture error: [^\"]*' | head -1)"
fi

# J1 — capture produced a file from the forked Maven test JVM.
step "J1: the documented recipe ran and capture wrote a trace file"
curl -fsS "${ART}/target/traces.json" -o "${TMP_DIR}/traces.json" 2>/dev/null
SPANS=0
[ -s "${TMP_DIR}/traces.json" ] && SPANS="$(python3 - "${TMP_DIR}/traces.json" <<'PY'
import json, sys
from collections import Counter
# Count the spans of the REQUEST trace, not every span in the file. The test
# creates its own schema before opening the request span, and those statements
# are instrumented too — they just land in their own single-span traces. Taking
# the largest trace is what "the request's spans all arrived" actually means.
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
PY
)"
EXPECTED_SPANS=$((ITEMS + 1))
if [ "${BUILD_RESULT}" = "SUCCESS" ] && [ "${SPANS}" = "${EXPECTED_SPANS}" ]; then
  assert_pass "J1" "build ${BUILD_RESULT}, ${SPANS} spans captured (${ITEMS} JDBC + 1 SERVER)"
else
  assert_fail "J1" "build=${BUILD_RESULT}, spans=${SPANS} (expected ${EXPECTED_SPANS}): $(grep -iE 'error|fail' "${TMP_DIR}/console.txt" | tail -2)"
fi

# J2 — the trace file is analyzable and carries the planted anti-pattern.
step "J2: analyze finds the planted n_plus_one_sql"
curl -fsS "${ART}/perf-sentinel-report.json" -o "${TMP_DIR}/findings.json" 2>/dev/null
OCC=0; TYPES=""
if [ -s "${TMP_DIR}/findings.json" ]; then
  read -r OCC TYPES <<< "$(python3 - "${TMP_DIR}/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
f = d.get("findings", [])
occ = [x.get("pattern", {}).get("occurrences", 0) for x in f if x.get("type") == "n_plus_one_sql"]
print(max(occ) if occ else 0, ",".join(sorted({x.get("type","") for x in f})) or "-")
PY
)"
fi
if [ "${OCC}" = "${ITEMS}" ]; then
  assert_pass "J2" "n_plus_one_sql at ${OCC} occurrences [${TYPES}]"
else
  assert_fail "J2" "occurrences=${OCC} (expected ${ITEMS}), types=[${TYPES}]"
fi

# J3 — Jenkins published the dashboard.
step "J3: report.html is published by Jenkins"
HTTP_HTML="$(curl -sS -o "${TMP_DIR}/report.html" -w '%{http_code}' "${ART}/report.html" 2>/dev/null)"
HTML_BYTES=$(wc -c < "${TMP_DIR}/report.html" 2>/dev/null | tr -d ' ')
if [ "${HTTP_HTML}" = "200" ] && [ "${HTML_BYTES}" -gt 100000 ]; then
  assert_pass "J3" "report.html served by Jenkins (${HTML_BYTES} bytes)"
else
  assert_fail "J3" "http=${HTTP_HTML}, bytes=${HTML_BYTES}"
fi

# J4 — the headline. Fetched through Jenkins, under Jenkins' own CSP.
step "J4: through Jenkins under its default CSP, the dashboard is blank"
JENKINS_CSP="$(curl -sS -D - -o /dev/null "${ART}/report.html" 2>/dev/null \
  | tr -d '\r' | awk 'tolower($1) == "content-security-policy:" {sub(/^[^:]*: */,""); print}' | head -1)"
J4="$(RENDER_CHECK_PORT=18897 "${RENDER_CHECK}" "${ART}/report.html" none "${TMP_DIR}/report.html" 2>"${TMP_DIR}/j4.err")"
J4_RC=$?
if [ "${J4_RC}" = "2" ]; then
  skip "render check unavailable: $(tail -1 "${TMP_DIR}/j4.err")"
  record "J4" "SKIP — $(tail -1 "${TMP_DIR}/j4.err")"
elif [ "${J4:0:5}" = "BLANK" ]; then
  # The documented limitation, reproduced in situ. Recorded rather than
  # asserted: a gate that turns red when the product IMPROVES is a bad gate.
  assert_pass "J4" "${J4} — the documented limitation reproduced under Jenkins' CSP [${JENKINS_CSP:-none advertised}]"
else
  assert_pass "J4" "${J4} — the dashboard now renders under Jenkins' default CSP. The limitation described in docs/CI.md:374-425 appears LIFTED; that doc section and this leg both need revisiting. CSP served: [${JENKINS_CSP:-none}]"
fi

# J5 — the remedy docs/CI.md prescribes, applied exactly as prescribed.
step "J5: with the documented Script Console remedy, it renders"
RELAXED="sandbox allow-scripts; default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline';"
jenkins_post "/scriptText" --data-urlencode \
  "script=System.setProperty(\"hudson.model.DirectoryBrowserSupport.CSP\", \"${RELAXED}\")" \
  > "${TMP_DIR}/script-console.log" 2>&1 \
  || die "the Script Console call failed: $(tail -2 "${TMP_DIR}/script-console.log")"
J5="$(RENDER_CHECK_PORT=18896 "${RENDER_CHECK}" "${ART}/report.html" none "${TMP_DIR}/report.html" 2>"${TMP_DIR}/j5.err")"
J5_RC=$?
if [ "${J5_RC}" = "2" ]; then
  skip "render check unavailable"
  record "J5" "SKIP — render check unavailable"
elif [ "${J5:0:8}" = "RENDERED" ]; then
  assert_pass "J5" "${J5} once DirectoryBrowserSupport.CSP is relaxed"
else
  assert_fail "J5" "the documented remedy did not restore rendering: ${J5}"
fi

# J8 — 0.9.25's answer to what this scenario reported: the report now opens with
# a plain unstyled notice naming both causes of a blank page, and a script right
# after it removes the notice during parsing. So the notice must be PRESENT
# exactly when the page failed to render and ABSENT when it rendered. Read off
# J4's and J5's own output rather than loading the page a third time.
step "J8: the blank page explains itself, and the notice disappears when it renders"
J8_BLOCKED="$(printf '%s' "${J4}" | sed -n 's/.*notice=\([a-z]*\).*/\1/p')"
J8_RENDERED="$(printf '%s' "${J5}" | sed -n 's/.*notice=\([a-z]*\).*/\1/p')"
if [ "${J4_RC}" = "2" ] || [ "${J5_RC}" = "2" ]; then
  skip "render check unavailable, no DOM to read the notice from"
  record "J8" "SKIP — render check unavailable"
elif [ "${J8_BLOCKED}" = "present" ] && [ "${J8_RENDERED}" = "absent" ]; then
  assert_pass "J8" "the #ps-no-js notice is present on the blocked page and gone once the script runs — a page that explains itself rather than a blank one"
elif [ -z "${J8_BLOCKED}" ] || [ -z "${J8_RENDERED}" ]; then
  record "J8" "SKIP — render-check reported no notice field (older helper?)"
  skip "render-check did not report a notice field"
else
  assert_fail "J8" "notice under CSP=${J8_BLOCKED} (want present), notice when rendered=${J8_RENDERED} (want absent)"
fi

# J7 — measure the promise at docs/CI.md:423 instead of trusting it.
step "J7: would 'CSS and JS in sibling files' survive that CSP? Measure it"
PROBE="${TMP_DIR}/sibling"
mkdir -p "${PROBE}"
cat > "${PROBE}/index.html" <<'EOF'
<!doctype html><html><head><link rel="stylesheet" href="r.css"></head>
<body><table><tbody id="b"><tr role="tab"><td>static</td></tr></tbody></table>
<script src="r.js"></script></body></html>
EOF
echo 'body{background:#eee}' > "${PROBE}/r.css"
echo 'document.getElementById("b").insertAdjacentHTML("beforeend","<tr role=\"tab\"><td>from-js</td></tr>");' \
  > "${PROBE}/r.js"
# Replay the CSP Jenkins actually served in J4, not an assumed one.
PROBE_CSP="${JENKINS_CSP:-sandbox; default-src 'none'; img-src 'self'; style-src 'self';}"
J7_OUT="$(RENDER_CHECK_PORT=18895 PROBE_CSP="${PROBE_CSP}" python3 - "${PROBE}" <<'PY' 2>/dev/null
import functools, http.server, os, subprocess, threading, sys
csp = os.environ["PROBE_CSP"]
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Content-Security-Policy", csp); super().end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 18895),
                             functools.partial(H, directory=sys.argv[1]))
threading.Thread(target=srv.serve_forever, daemon=True).start()
chrome = next((c for c in [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"] if os.path.exists(c)), None)
if not chrome:
    print("SKIP"); srv.shutdown(); raise SystemExit
dom = subprocess.run([chrome, "--headless=new", "--disable-gpu", "--no-sandbox",
                      "--virtual-time-budget=3000", "--dump-dom",
                      "http://127.0.0.1:18895/index.html"],
                     capture_output=True, text=True).stdout
srv.shutdown()
print("EXECUTED" if "from-js" in dom else "BLOCKED")
PY
)"
if [ "${J7_OUT}" = "SKIP" ]; then
  skip "no browser for the sibling-files probe"
  record "J7" "SKIP — no browser"
elif [ "${J7_OUT}" = "BLOCKED" ]; then
  assert_pass "J7" "external sibling JS is BLOCKED too — the documented future fix would not help on this CSP"
else
  assert_fail "J7" "external sibling JS executed (${J7_OUT}); the documented future fix may be viable after all"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The documented Java CI recipe run inside a real Jenkins, through to whether"
  echo "the published dashboard renders in a browser."
  echo ""
  echo "Jenkins served: \`${JENKINS_CSP:-no Content-Security-Policy header}\`"
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
