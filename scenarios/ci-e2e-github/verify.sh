#!/usr/bin/env bash
# ci-e2e-github: the documented Java CI recipe run through a real GitHub Actions
# workflow (executed locally by act), through to whether the published dashboard
# renders in a browser.
#
# What is genuinely different from ci-e2e-jenkins: on GitHub the display risk is
# LOW by construction. Job artifacts are zip downloads that GitHub never renders,
# and GitHub Pages serves HTML without a restrictive Content-Security-Policy —
# unlike Jenkins, which serves build artifacts through DirectoryBrowserSupport
# under a CSP that blanks the dashboard. So the value here is the chain, not the
# CSP: the workflow really runs, capture really writes the file, and what lands
# on Pages really renders.
#
# Assertions (see README.md):
#   H1  act runs the workflow to completion, HTML steps included
#   H2  capture wrote a complete trace file and analyze finds the planted N+1
#   H3  report.html is produced and lands where the workflow publishes it
#   H4  served the way GitHub Pages serves it, the dashboard renders
#
# Self-contained: no cluster. Needs Docker, act, python3 and Chrome.
set -uo pipefail

SCENARIO="ci-e2e-github"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_CHECK="${SCRIPT_DIR}/../ci-e2e-common/render-check.sh"
JAVA_FIXTURES="${SCRIPT_DIR}/../java-ci-capture/fixtures"

PERF_SENTINEL_IMAGE="${PERF_SENTINEL_IMAGE:-ghcr.io/robintra/perf-sentinel:0.11.1}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18.4-alpine}"
NETWORK="ghe2e-net"
PG_CONTAINER="ghe2e-postgres"
# catthehacker/ubuntu is what act itself recommends for ubuntu-latest.
ACT_RUNNER_IMAGE="${ACT_RUNNER_IMAGE:-catthehacker/ubuntu:act-24.04}"
ITEMS=15
WORKDIR="${TMP_DIR}/repo"

rm -rf "${TMP_DIR}"; mkdir -p "${WORKDIR}"

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
  docker rm -f ghe2e-extract "${PG_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── preflight ───────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  || die "Docker unavailable — act runs the workflow in containers"
command -v act >/dev/null 2>&1 \
  || die "act not installed (brew install act) — this scenario runs the real workflow"
[ -x "${RENDER_CHECK}" ] || die "missing ${RENDER_CHECK}"
[ -f "${JAVA_FIXTURES}/pom.xml" ] || die "missing the Maven fixture at ${JAVA_FIXTURES}"


# act does not give the runner container the hostname alias of a `services:`
# block, so PostgreSQL runs on a named network the runner is attached to and is
# reached by container name. Seeding here also spares the workflow an apt-get.
step "Throwaway PostgreSQL on the ${NETWORK} network"
docker network create "${NETWORK}" >/dev/null 2>&1 || true
docker rm -f "${PG_CONTAINER}" >/dev/null 2>&1 || true
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

# ── assemble the repository act will run against ────────────────────────────
step "Assemble a repository: workflow, Maven project, released binary"
mkdir -p "${WORKDIR}/.github/workflows"
cp "${SCRIPT_DIR}/fixtures/workflow.yml" "${WORKDIR}/.github/workflows/perf-sentinel.yml"
cp -R "${JAVA_FIXTURES}" "${WORKDIR}/project"
rm -rf "${WORKDIR}/project/target"

# The released image is FROM scratch with a single static binary; taking the
# binary from there is both the artifact a user installs and the only way to get
# a Linux binary from a macOS host.
docker rm -f ghe2e-extract >/dev/null 2>&1 || true
docker create --name ghe2e-extract "${PERF_SENTINEL_IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${PERF_SENTINEL_IMAGE}"
docker cp ghe2e-extract:/perf-sentinel "${WORKDIR}/perf-sentinel" >/dev/null 2>&1 \
  || die "cannot extract the binary from ${PERF_SENTINEL_IMAGE}"
docker rm -f ghe2e-extract >/dev/null 2>&1 || true
chmod +x "${WORKDIR}/perf-sentinel"
ok "repository assembled at ${WORKDIR}"

# act wants a git repository to derive its event context from.
( cd "${WORKDIR}" && git init -q && git add -A && \
  git -c user.email=lab@example.com -c user.name=lab commit -qm "e2e fixture" ) \
  || die "cannot initialise the fixture repository"

# ── run the workflow ────────────────────────────────────────────────────────
# --bind mounts the working directory instead of copying it into the runner:
# without it act's copy stays inside the container and the workflow's outputs —
# the trace file, the report, the Pages directory — never reach the host.
step "act: run the workflow (first run pulls the runner image, allow time)"
ACT_RC=0
( cd "${WORKDIR}" && act push \
    -P "ubuntu-latest=${ACT_RUNNER_IMAGE}" \
    --network "${NETWORK}" \
    --pull=false \
    --bind \
    ) > "${TMP_DIR}/act.log" 2>&1 || ACT_RC=$?

# H1 — the workflow ran end to end.
step "H1: act ran the workflow to completion"
JOB_OK=0
grep -qE "Job succeeded" "${TMP_DIR}/act.log" && JOB_OK=1
if [ "${ACT_RC}" = "0" ] && [ "${JOB_OK}" = "1" ]; then
  assert_pass "H1" "the workflow ran to completion under act"
else
  assert_fail "H1" "act rc=${ACT_RC}: $(grep -iE '❌|error|failure' "${TMP_DIR}/act.log" | tail -2 | tr '\n' ' ')"
fi

# H2 — capture wrote a usable trace file and it carries the anti-pattern.
step "H2: capture wrote the trace file and analyze finds the planted N+1"
SPANS=0
if [ -s "${WORKDIR}/target/traces.json" ]; then
  SPANS="$(python3 - "${WORKDIR}/target/traces.json" <<'PY'
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
OCC=0
if [ -s "${WORKDIR}/perf-sentinel-report.json" ]; then
  OCC="$(python3 - "${WORKDIR}/perf-sentinel-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
occ = [x.get("pattern", {}).get("occurrences", 0)
       for x in d.get("findings", []) if x.get("type") == "n_plus_one_sql"]
print(max(occ) if occ else 0)
PY
)"
fi
EXPECTED_SPANS=$((ITEMS + 1))
if [ "${SPANS}" = "${EXPECTED_SPANS}" ] && [ "${OCC}" = "${ITEMS}" ]; then
  assert_pass "H2" "${SPANS} spans captured, n_plus_one_sql at ${OCC} occurrences"
else
  assert_fail "H2" "spans=${SPANS} (expected ${EXPECTED_SPANS}), occurrences=${OCC} (expected ${ITEMS})"
fi

# H3 — the dashboard was produced and published where the workflow puts it.
step "H3: report.html lands in the Pages directory"
PAGES="${WORKDIR}/public/index.html"
BYTES=0
[ -s "${PAGES}" ] && BYTES=$(wc -c < "${PAGES}" | tr -d ' ')
if [ "${BYTES}" -gt 100000 ]; then
  assert_pass "H3" "public/index.html published (${BYTES} bytes)"
else
  assert_fail "H3" "public/index.html is ${BYTES} bytes"
fi

# H4 — GitHub Pages serves without a restrictive CSP, so the dashboard should
# render. Measured rather than assumed: that is the whole point of the family.
step "H4: served the way GitHub Pages serves it, the dashboard renders"
if [ "${BYTES}" -gt 0 ]; then
  H4="$(RENDER_CHECK_PORT=18894 "${RENDER_CHECK}" "${PAGES}" none 2>"${TMP_DIR}/h4.err")"
  H4_RC=$?
  if [ "${H4_RC}" = "2" ]; then
    skip "render check unavailable: $(tail -1 "${TMP_DIR}/h4.err")"
    record "H4" "SKIP — $(tail -1 "${TMP_DIR}/h4.err")"
  # `notice=absent` is the second half: 0.9.25 opens the report with a plain
  # #ps-no-js block that a script removes during parsing. On a path that renders,
  # a visible notice would be a new display defect of its own.
  elif [ "${H4:0:8}" = "RENDERED" ] && [[ "${H4}" == *"notice=absent"* ]]; then
    assert_pass "H4" "${H4} — no restrictive CSP on the Pages path, and the no-JS notice was removed during parsing"
  elif [ "${H4:0:8}" = "RENDERED" ]; then
    assert_fail "H4" "the dashboard rendered but the no-JS notice is still painted: ${H4}"
  else
    assert_fail "H4" "the dashboard did not render even without a restrictive CSP: ${H4}"
  fi
else
  assert_fail "H4" "no published report to render"
fi

# =============================================================================
verdict=$([ "${FAILS}" -eq 0 ] && echo PASS || echo FAIL)
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "The documented Java CI recipe run through a real GitHub Actions workflow"
  echo "(executed by act), through to whether the published dashboard renders."
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
