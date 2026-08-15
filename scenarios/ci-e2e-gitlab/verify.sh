#!/usr/bin/env bash
# ci-e2e-gitlab: the documented Java CI recipe run by a REAL GitLab pipeline on
# the lab's Kubernetes runner, through to the dashboard served by GitLab Pages.
#
# This is the only one of the ci-e2e-* family with a genuine CI engine already in
# the lab: `make up-gitlab` deploys GitLab CE with a Kubernetes-executor runner
# that runs real pipelines. It also closes a gap the lab documented against
# itself — docs/GITLAB-CI.md:83-86 notes that the Pages job produces
# public/index.html but that ${CI_PAGES_URL} is never fetched over HTTP.
#
# Assertions (see README.md):
#   G1  the pipeline runs on the runner and capture writes a complete trace file
#   G2  analyze finds the planted n_plus_one_sql with the expected occurrences
#   G3  the Pages job publishes public/index.html
#   G4  fetched from GitLab Pages OVER HTTP, the dashboard renders
#
# Needs the cluster, `make up-gitlab` and `make seed-gitlab-project`.
set -uo pipefail

SCENARIO="ci-e2e-gitlab"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_CHECK="${SCRIPT_DIR}/../ci-e2e-common/render-check.sh"
JAVA_FIXTURES="${SCRIPT_DIR}/../java-ci-capture/fixtures"

GITLAB_URL="${GITLAB_URL:-http://localhost:8181}"
PAT_FILE="${PAT_FILE:-/tmp/gitlab-pat.txt}"
PROJECT_NAME="${PROJECT_NAME:-perf-sentinel-template-test}"
ROOT_USER="root"
PERF_SENTINEL_IMAGE="${PERF_SENTINEL_IMAGE:-ghcr.io/robintra/perf-sentinel:0.13.1}"
PAGES_PORT="${PAGES_PORT:-18190}"
PAGES_HOST="${ROOT_USER}.pages.localhost"
PIPELINE_TIMEOUT_S="${PIPELINE_TIMEOUT_S:-1200}"
ITEMS=15

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

PF_PID=""
cleanup() {
  if [ -n "${PF_PID}" ]; then
    kill "${PF_PID}" 2>/dev/null
    wait "${PF_PID}" 2>/dev/null
  fi
  docker rm -f gle2e-extract >/dev/null 2>&1 || true
  rm -f "${TMP_DIR}/askpass.sh"
}
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
[ -x "${RENDER_CHECK}" ] || die "missing ${RENDER_CHECK}"
[ -f "${JAVA_FIXTURES}/pom.xml" ] || die "missing the Maven fixture at ${JAVA_FIXTURES}"
command -v docker >/dev/null 2>&1 || die "docker needed to extract the released binary"
curl -fsS -o /dev/null "${GITLAB_URL}/-/health" 2>/dev/null \
  || { skip "GitLab not reachable at ${GITLAB_URL} — run make up-gitlab && make seed-gitlab-project"
       record "G1" "SKIP — no GitLab"; record "G2" "SKIP — no GitLab"
       record "G3" "SKIP — no GitLab"; record "G4" "SKIP — no GitLab"
       verdict="SKIP"; FAILS=0
       { echo "# Scenario: ${SCENARIO}"; echo; echo "GitLab CE unavailable."; } > "${REPORT}"
       color_yellow "SKIP — GitLab CE is not up"; exit 0; }
[ -s "${PAT_FILE}" ] || die "no PAT at ${PAT_FILE} — run make seed-gitlab-project"
TOKEN="$(cat "${PAT_FILE}")"

api() { curl -fsS -H "PRIVATE-TOKEN: ${TOKEN}" "$@"; }
PROJECT_ID="$(api "${GITLAB_URL}/api/v4/projects?owned=true&search=${PROJECT_NAME}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
[ -n "${PROJECT_ID}" ] || die "project ${PROJECT_NAME} not found — run make seed-gitlab-project"
ok "project ${PROJECT_NAME} id=${PROJECT_ID}"

# ── push the pipeline and the Maven project ─────────────────────────────────
step "Push the e2e pipeline, the Maven project and the released binary"
WORK="${TMP_DIR}/repo"
cat > "${TMP_DIR}/askpass.sh" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  Username*) echo oauth2 ;;
  Password*) echo "${LAB_GIT_TOKEN}" ;;
esac
ASKPASS
chmod 700 "${TMP_DIR}/askpass.sh"
export LAB_GIT_TOKEN="${TOKEN}" GIT_ASKPASS="${TMP_DIR}/askpass.sh"
# A configured credential helper (osxkeychain is Git for Mac's default) is
# consulted BEFORE GIT_ASKPASS, and it caches per host:port. Every `make
# up-gitlab` mints a new PAT for the same localhost:8181, so the second GitLab
# instance on a machine authenticates with the first one's stale token and fails
# with "HTTP Basic: Access denied" — while the PAT itself is valid and the API
# accepts it, which sends you looking at GitLab rather than at the keychain.
# Emptying the helper for these commands only neutralises it here; the user's
# own git config is untouched.
GIT_NO_HELPER=(-c credential.helper=)
git "${GIT_NO_HELPER[@]}" clone -q "${GITLAB_URL}/${ROOT_USER}/${PROJECT_NAME}.git" "${WORK}" \
  || die "cannot clone the seeded project"

# One Maven project across the three ci-e2e scenarios: copied in, never forked.
rm -rf "${WORK}/project"
cp -R "${JAVA_FIXTURES}" "${WORK}/project"
rm -rf "${WORK}/project/target"
cp "${SCRIPT_DIR}/fixtures/gitlab-ci.yml" "${WORK}/.gitlab-ci.yml"

# The released image is FROM scratch with one static binary. Committing it keeps
# the runner free of any egress to github.com, and gives the arm64 lab an arm64
# binary rather than the amd64 release asset.
docker rm -f gle2e-extract >/dev/null 2>&1 || true
docker create --name gle2e-extract "${PERF_SENTINEL_IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${PERF_SENTINEL_IMAGE}"
docker cp gle2e-extract:/perf-sentinel "${WORK}/perf-sentinel" >/dev/null 2>&1 \
  || die "cannot extract the binary"
docker rm -f gle2e-extract >/dev/null 2>&1 || true

# --allow-empty on purpose: a re-run with unchanged fixtures must still create a
# commit, or no pipeline is triggered and the scenario silently reports the
# previous run's verdict.
( cd "${WORK}" && git add -A \
  && git -c user.email=lab@example.com -c user.name=lab commit -q --allow-empty \
       -m "ci-e2e-gitlab: capture to rendered dashboard" \
  && git "${GIT_NO_HELPER[@]}" push -q origin HEAD:main ) || die "cannot push the pipeline"
SHA="$(cd "${WORK}" && git rev-parse HEAD)"
ok "pushed ${SHA:0:8}"

# ── wait for the pipeline ───────────────────────────────────────────────────
step "Wait for the pipeline on the Kubernetes runner (Maven resolves from scratch)"
PIPELINE_ID=""
for _ in $(seq 1 60); do
  PIPELINE_ID="$(api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines?sha=${SHA}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)"
  [ -n "${PIPELINE_ID}" ] && break
  sleep 5
done
[ -n "${PIPELINE_ID}" ] || die "no pipeline was created for ${SHA:0:8}"
STATUS=""
for _ in $(seq 1 $((PIPELINE_TIMEOUT_S / 10))); do
  STATUS="$(api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines/${PIPELINE_ID}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)"
  case "${STATUS}" in success|failed|canceled|skipped) break ;; esac
  sleep 10
done
ok "pipeline ${PIPELINE_ID} finished with status=${STATUS}"
api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/pipelines/${PIPELINE_ID}/jobs" \
  > "${TMP_DIR}/jobs.json" 2>/dev/null

job_id() {  # $1 = job name
  python3 - "${TMP_DIR}/jobs.json" "$1" <<'PY'
import json, sys
jobs = json.load(open(sys.argv[1]))
m = [j for j in jobs if j["name"] == sys.argv[2]]
print(m[0]["id"] if m else "")
PY
}
fetch_artifacts() {  # $1 = job id ; $2 = destination dir
  local zip="${TMP_DIR}/art-$1.zip"
  api "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/jobs/$1/artifacts" -o "${zip}" 2>/dev/null || return 1
  mkdir -p "$2" && unzip -oq "${zip}" -d "$2" 2>/dev/null
}

# G1 — the pipeline really ran the recipe on the runner.
step "G1: the pipeline ran the recipe and capture wrote a trace file"
IT_JOB="$(job_id integration-tests)"
SPANS=0
if [ -n "${IT_JOB}" ] && fetch_artifacts "${IT_JOB}" "${TMP_DIR}/it"; then
  [ -s "${TMP_DIR}/it/target/traces.json" ] && SPANS="$(python3 - "${TMP_DIR}/it/target/traces.json" <<'PY'
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
fi
EXPECTED_SPANS=$((ITEMS + 1))
if [ "${SPANS}" = "${EXPECTED_SPANS}" ]; then
  assert_pass "G1" "${SPANS} spans captured by the runner (${ITEMS} JDBC + 1 SERVER)"
else
  assert_fail "G1" "spans=${SPANS} (expected ${EXPECTED_SPANS}), pipeline status=${STATUS}, job=${IT_JOB:-missing}"
fi

# G2 — the trace file carries the planted anti-pattern.
step "G2: analyze finds the planted n_plus_one_sql"
PS_JOB="$(job_id perf-sentinel)"
OCC=0
if [ -n "${PS_JOB}" ] && fetch_artifacts "${PS_JOB}" "${TMP_DIR}/ps"; then
  [ -s "${TMP_DIR}/ps/perf-sentinel-report.json" ] && OCC="$(python3 - "${TMP_DIR}/ps/perf-sentinel-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
occ = [x.get("pattern", {}).get("occurrences", 0)
       for x in d.get("findings", []) if x.get("type") == "n_plus_one_sql"]
print(max(occ) if occ else 0)
PY
)"
fi
if [ "${OCC}" = "${ITEMS}" ]; then
  assert_pass "G2" "n_plus_one_sql at ${OCC} occurrences"
else
  assert_fail "G2" "occurrences=${OCC} (expected ${ITEMS}), job=${PS_JOB:-missing}"
fi

# G3 — the Pages job published the dashboard.
step "G3: the Pages job publishes public/index.html"
PAGES_JOB="$(job_id pages)"
PAGES_BYTES=0
if [ -n "${PAGES_JOB}" ] && fetch_artifacts "${PAGES_JOB}" "${TMP_DIR}/pages"; then
  [ -s "${TMP_DIR}/pages/public/index.html" ] \
    && PAGES_BYTES=$(wc -c < "${TMP_DIR}/pages/public/index.html" | tr -d ' ')
fi
if [ "${PAGES_BYTES}" -gt 100000 ]; then
  assert_pass "G3" "public/index.html published (${PAGES_BYTES} bytes)"
else
  assert_fail "G3" "public/index.html is ${PAGES_BYTES} bytes, job=${PAGES_JOB:-missing}"
fi

# G4 — the gap docs/GITLAB-CI.md:83-86 admits: actually fetch Pages over HTTP.
# GitLab Pages routes on the Host header; *.localhost resolves to 127.0.0.1, so
# a port-forward plus the real hostname is enough, with no /etc/hosts surgery.
step "G4: fetch the dashboard from GitLab Pages over HTTP and render it"
if [ "${PAGES_BYTES}" -le 0 ]; then
  assert_fail "G4" "nothing was published to Pages to fetch"
else
  # Port 9090 on the POD, not 8090 on the service: 8090 is the PROXY listener
  # (it expects PROXY-protocol headers), 9090 is plain HTTP.
  PAGES_POD="$(kubectl -n gitlab-ce get pod --no-headers 2>/dev/null \
    | grep pages | awk '{print $1}' | head -1)"
  [ -n "${PAGES_POD}" ] || die "no GitLab Pages pod found"
  kubectl -n gitlab-ce port-forward "${PAGES_POD}" "${PAGES_PORT}:9090" \
    > "${TMP_DIR}/pf.log" 2>&1 &
  PF_PID=$!
  PAGES_URL="http://${PAGES_HOST}:${PAGES_PORT}/${PROJECT_NAME}/"
  LIVE=0
  # -L on purpose: GitLab serves each project on a unique domain
  # (<project>-<hash>.pages.localhost) and 308-redirects the namespace URL to it.
  # Chrome follows that redirect natively, and *.localhost resolves to 127.0.0.1,
  # so the forwarded port survives the hop.
  for _ in $(seq 1 60); do
    CODE="$(curl -sSL -o /dev/null -w '%{http_code}' "${PAGES_URL}" 2>/dev/null)"
    [ "${CODE}" = "200" ] && { LIVE=1; break; }
    sleep 5
  done
  if [ "${LIVE}" != "1" ]; then
    assert_fail "G4" "Pages never served ${PAGES_URL} (last http=${CODE:-none}); the deployment may still be processing"
  else
    G4="$(RENDER_CHECK_PORT=18893 "${RENDER_CHECK}" "${PAGES_URL}" none \
      "${TMP_DIR}/pages/public/index.html" 2>"${TMP_DIR}/g4.err")"
    G4_RC=$?
    if [ "${G4_RC}" = "2" ]; then
      skip "render check unavailable: $(tail -1 "${TMP_DIR}/g4.err")"
      record "G4" "SKIP — $(tail -1 "${TMP_DIR}/g4.err")"
    # `notice=absent` is the second half: 0.9.25 opens the report with a plain
    # #ps-no-js block that a script removes during parsing. On a path that
    # renders, a visible notice would be a new display defect of its own.
    elif [ "${G4:0:8}" = "RENDERED" ] && [[ "${G4}" == *"notice=absent"* ]]; then
      assert_pass "G4" "${G4} — served by GitLab Pages at ${PAGES_URL}, and the no-JS notice was removed during parsing"
    elif [ "${G4:0:8}" = "RENDERED" ]; then
      assert_fail "G4" "the dashboard rendered but the no-JS notice is still painted: ${G4}"
    else
      assert_fail "G4" "served by GitLab Pages but the dashboard did not render: ${G4}"
    fi
  fi
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The documented Java CI recipe run by a real GitLab pipeline on the lab's"
  echo "Kubernetes runner, through to the dashboard served by GitLab Pages."
  echo ""
  echo "Pipeline ${PIPELINE_ID:-none} on ${SHA:0:8}: status ${STATUS:-unknown}"
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
