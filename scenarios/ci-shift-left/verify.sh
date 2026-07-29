#!/usr/bin/env bash
# CI shift-left workflow validation, post-0.5.17.
#
# 3 phases that mirror the canonical perf-sentinel CI use case:
#
#   Phase 1, clean baseline. Filter the lab fixture
#   `artifacts/fixtures/em-real-time-traces.json` to keep only traces
#   that do not hit `/api/fault/*` endpoints (~79 of 149 traces, mostly
#   health probes and normal /api/orders calls). Run `analyze --ci`
#   with strict thresholds. Asserts the gate passes (exit 0).
#
#   Phase 2, regression. Run `analyze --ci --format json` then
#   `analyze --format sarif` against the FULL fixture (149 traces, with
#   the 70 fault traces). Asserts: gate fails (exit != 0), > 5 active
#   findings, every JSON finding has a non-empty `signature` (0.5.17
#   feature), SARIF parses against the 2.1.0 schema.
#
#   Phase 3, acked. Generate `.perf-sentinel-acknowledgments.toml` from
#   the unique signatures of phase 2, re-run analyze with
#   `--acknowledgments` active. Asserts: gate passes (acks excluded),
#   0 active findings. Also runs `--show-acknowledged` and verifies
#   suppressed findings surface in the output.
#
# Why fixture, not daemon export?
#   /api/export/report returns a post-analysis Report (findings already
#   computed), not the raw OTLP traces that `analyze` consumes. The
#   lab fixture (Jaeger JSON, ~7 MB, 149 traces) is the input shape the
#   CLI expects. The k6 + daemon stack stays operational for other
#   scenarios but is not required by this one beyond a sanity ping.
#
# Outputs (consumed by output-formats-coverage):
#   /tmp/scenario-ci-shift-left-report.md     verdict + assertions
#   /tmp/ci-shift-left/baseline-traces.json   filtered fixture (clean)
#   /tmp/ci-shift-left/regression-traces.json full fixture
#   /tmp/ci-shift-left/baseline.json          analyzed clean (Report JSON)
#   /tmp/ci-shift-left/regression.json        analyzed regression
#   /tmp/ci-shift-left/regression.sarif       SARIF v2.1.0
#   /tmp/ci-shift-left/.perf-sentinel-acknowledgments.toml
#
# Optional knobs:
#   PERF_SENTINEL_VERSION  override CLI image tag (default 0.5.17)
#   SKIP_DAEMON_CHECK=1    skip the cluster sanity ping (run offline)

set -euo pipefail

SCENARIO="ci-shift-left"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
CONFIG_TOML="${SCENARIO_DIR}/.perf-sentinel.toml"
TRACES_FIXTURE="${LAB_ROOT}/artifacts/fixtures/em-real-time-traces.json"

# Default to the image the lab's daemon manifest pins, so these scenarios track
# the version under validation instead of drifting away from it. They sat on a
# hardcoded 0.5.17 for several minor releases, which meant the CI path was never
# exercised against the version being validated, and it kept reporting a SARIF
# gap the product had closed in 0.9.0.
#
# PERF_SENTINEL_VERSION still overrides, as a GHCR tag. The manifest reference is
# used verbatim otherwise: it may be a digest pin or a local pre-release tag left
# by scripts/seed-daemon-local.sh, and neither can be rebuilt from a version
# string.
if [ -n "${PERF_SENTINEL_VERSION:-}" ]; then
  IMAGE="ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}"
else
  IMAGE="$(awk '/^[[:space:]]*image:[[:space:]]*(ghcr\.io\/robintra\/)?perf-sentinel[:@]/ { print $2; exit }' \
    "${LAB_ROOT}/manifests/perf-sentinel-daemon.yaml")"
  # Not `die`: the colour helpers are defined further down in both scenarios.
  [ -n "${IMAGE}" ] || {
    printf "    error: cannot derive the perf-sentinel image from manifests/perf-sentinel-daemon.yaml\n" >&2
    exit 1
  }
fi
DAEMON_PORT_LOCAL=14318

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

if [ "$(uname -s)" = "Linux" ]; then
  DOCKER_NET_FLAGS=(--network host)
else
  DOCKER_NET_FLAGS=(--add-host=host.docker.internal:host-gateway)
fi

# === Pre-flight ===
step "0. Pre-flight"

command -v docker  >/dev/null || die "docker not on PATH"
command -v jq      >/dev/null || die "jq not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"

[ -f "${TRACES_FIXTURE}" ] \
  || die "trace fixture not found at ${TRACES_FIXTURE}"

docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}, check network or version pin"
ok "image ${IMAGE} available"

# Sanity ping on the daemon (cluster healthy). Optional.
if [ "${SKIP_DAEMON_CHECK:-0}" != "1" ] && command -v kubectl >/dev/null; then
  if kubectl get nodes >/dev/null 2>&1; then
    if kubectl -n observability get deploy perf-sentinel-daemon >/dev/null 2>&1; then
      kubectl -n observability port-forward svc/perf-sentinel-daemon \
        "${DAEMON_PORT_LOCAL}:14318" \
        > "${TMP_DIR}/pf-daemon.log" 2>&1 &
      PIDS+=("$!")
      sleep 3
      if curl -sf "http://localhost:${DAEMON_PORT_LOCAL}/api/status" >/dev/null 2>&1; then
        ok "daemon reachable on localhost:${DAEMON_PORT_LOCAL} (sanity)"
      else
        warn "daemon not reachable; continuing with fixture-only flow"
      fi
    fi
  fi
fi

# Stage everything inside TMP_DIR so docker run uses a single mount.
cp "${CONFIG_TOML}" "${TMP_DIR}/.perf-sentinel.toml"
cp "${TRACES_FIXTURE}" "${TMP_DIR}/regression-traces.json"

# === Phase 1: clean baseline ===
step "1. Clean baseline (filter fixture for fault-free traces)"

python3 -c "
import json
data = json.load(open('${TRACES_FIXTURE}'))
traces = data['data']
clean = [t for t in traces
         if not any('fault' in s.get('operationName', '').lower() for s in t.get('spans', []))]
json.dump({'data': clean}, open('${TMP_DIR}/baseline-traces.json', 'w'))
print(f'kept {len(clean)}/{len(traces)} fault-free traces')
" > "${TMP_DIR}/clean-filter.log" 2>&1 \
  || die "fixture filter failed, see ${TMP_DIR}/clean-filter.log"
ok "$(cat "${TMP_DIR}/clean-filter.log")"

step "1.b. Quality gate on baseline (must PASS)"

# analyze writes the chosen format to stdout (no --output flag), so we
# redirect explicitly. Capture stderr to a separate log.
docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/baseline-traces.json \
  --config /workdir/.perf-sentinel.toml \
  --format json \
  --ci \
  > "${TMP_DIR}/baseline.json" 2> "${TMP_DIR}/baseline-analyze.log" \
  && CLEAN_EXIT=0 || CLEAN_EXIT=$?

if [ "${CLEAN_EXIT}" -eq 0 ]; then
  CLEAN_GATE="PASS"
  ok "clean baseline gate PASS (exit 0)"
else
  CLEAN_GATE="FAIL"
  warn "clean baseline gate FAIL (exit ${CLEAN_EXIT}); the filtered fixture still has some traces tripping strict thresholds"
fi

[ -s "${TMP_DIR}/baseline.json" ] || die "baseline analyze produced empty JSON, see ${TMP_DIR}/baseline-analyze.log"
BASELINE_ANALYZED=$(jq '.findings | length' "${TMP_DIR}/baseline.json")
ok "baseline produced ${BASELINE_ANALYZED} findings"

# === Phase 2: regression ===
step "2. Regression (full fixture, must FAIL the gate)"

docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/regression-traces.json \
  --config /workdir/.perf-sentinel.toml \
  --format json \
  --ci \
  > "${TMP_DIR}/regression.json" 2> "${TMP_DIR}/regression-analyze.log" \
  && REG_EXIT=0 || REG_EXIT=$?

if [ "${REG_EXIT}" -eq 0 ]; then
  REG_GATE="PASS"
  warn "regression analyze exited 0, gate did not fail"
else
  REG_GATE="FAIL"
  ok "regression analyze exited ${REG_EXIT}, gate fails as expected"
fi

[ -s "${TMP_DIR}/regression.json" ] || die "regression analyze produced empty JSON"

# SARIF, second invocation, no --ci (we just want the file).
docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/regression-traces.json \
  --config /workdir/.perf-sentinel.toml \
  --format sarif \
  > "${TMP_DIR}/regression.sarif" 2> "${TMP_DIR}/regression-sarif.log" \
  || die "SARIF analyze failed, see ${TMP_DIR}/regression-sarif.log"

step "2.b. Assertions"

ANALYZED_COUNT=$(jq '.findings | length' "${TMP_DIR}/regression.json")
ok "analyzed findings: ${ANALYZED_COUNT}"

if [ "${ANALYZED_COUNT}" -gt 5 ]; then
  ASSERT_COUNT="PASS"
  ok "assertion >5 findings PASS"
else
  ASSERT_COUNT="FAIL"
  warn "expected > 5 findings, got ${ANALYZED_COUNT}"
fi

WITH_SIG=$(jq '[.findings[] | select(.signature != null and .signature != "")] | length' \
  "${TMP_DIR}/regression.json")
if [ "${WITH_SIG}" = "${ANALYZED_COUNT}" ] && [ "${ANALYZED_COUNT}" -gt 0 ]; then
  ASSERT_SIG="PASS"
  ok "assertion signature on every finding PASS (${WITH_SIG}/${ANALYZED_COUNT})"
else
  ASSERT_SIG="FAIL"
  warn "signature populated on ${WITH_SIG}/${ANALYZED_COUNT} findings"
fi

if python3 -c "
import json, sys
sarif = json.load(open('${TMP_DIR}/regression.sarif'))
assert sarif.get('version') == '2.1.0', f'unexpected version: {sarif.get(\"version\")}'
runs = sarif.get('runs', [])
assert runs, 'no runs in SARIF'
assert runs[0]['tool']['driver']['name'] == 'perf-sentinel'
print(f'sarif valid, {sum(len(r.get(\"results\", [])) for r in runs)} results')
" > "${TMP_DIR}/sarif-check.log" 2>&1
then
  ASSERT_SARIF="PASS"
  ok "assertion SARIF schema PASS ($(cat "${TMP_DIR}/sarif-check.log"))"
else
  ASSERT_SARIF="FAIL"
  warn "SARIF schema check failed, see ${TMP_DIR}/sarif-check.log"
fi

# === Phase 3: ack workflow ===
step "3. Ack workflow (generate, re-analyze, --show-acknowledged)"

jq -r '.findings[].signature' "${TMP_DIR}/regression.json" \
  | grep -v '^$' | sort -u > "${TMP_DIR}/signatures-to-ack.txt"
SIG_COUNT=$(wc -l < "${TMP_DIR}/signatures-to-ack.txt" | tr -d ' ')
ok "extracted ${SIG_COUNT} unique signatures"

if [ "${SIG_COUNT}" -eq 0 ]; then
  die "no signatures to ack (regression analyze likely produced 0 findings or signatures absent in 0.5.17)"
fi

{
  printf '# B1 ci-shift-left scenario: acks generated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS= read -r sig; do
    [ -z "${sig}" ] && continue
    cat <<EOF

[[acknowledged]]
signature = "${sig}"
acknowledged_by = "ci-shift-left@perf-sentinel-lab.invalid"
acknowledged_at = "$(date +%Y-%m-%d)"
reason = "B1 scenario: validating ack workflow end-to-end"
EOF
  done < "${TMP_DIR}/signatures-to-ack.txt"
} > "${TMP_DIR}/.perf-sentinel-acknowledgments.toml"

ACK_BYTES=$(wc -c < "${TMP_DIR}/.perf-sentinel-acknowledgments.toml")
ok "ack file generated, ${ACK_BYTES} bytes"

docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/regression-traces.json \
  --config /workdir/.perf-sentinel.toml \
  --acknowledgments /workdir/.perf-sentinel-acknowledgments.toml \
  --format json \
  --ci \
  > "${TMP_DIR}/acked.json" 2> "${TMP_DIR}/acked-analyze.log" \
  && ACKED_EXIT=0 || ACKED_EXIT=$?

if [ "${ACKED_EXIT}" -eq 0 ]; then
  ACKED_GATE="PASS"
  ok "acked gate PASS (exit 0, all findings excluded)"
else
  ACKED_GATE="FAIL"
  warn "acked gate FAIL (exit ${ACKED_EXIT}, see ${TMP_DIR}/acked-analyze.log)"
fi

ACTIVE_AFTER_ACK=$(jq '.findings | length' "${TMP_DIR}/acked.json" 2>/dev/null || echo "?")
if [ "${ACTIVE_AFTER_ACK}" = "0" ]; then
  ASSERT_ACK_ZERO="PASS"
  ok "assertion 0 active findings after ack PASS"
else
  ASSERT_ACK_ZERO="FAIL"
  warn "expected 0 active findings, got ${ACTIVE_AFTER_ACK}"
fi

# Re-run with --show-acknowledged to verify ack metadata is surfaced.
docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/regression-traces.json \
  --config /workdir/.perf-sentinel.toml \
  --acknowledgments /workdir/.perf-sentinel-acknowledgments.toml \
  --show-acknowledged \
  --format json \
  > "${TMP_DIR}/acked-show.json" 2> "${TMP_DIR}/acked-show.log" \
  || warn "--show-acknowledged exited non-zero, see ${TMP_DIR}/acked-show.log"

ACKED_SHOWN=$(jq '
  if has("acknowledged_findings") then (.acknowledged_findings | length)
  elif (.findings // []) | length > 0 then ([.findings[] | select(.acknowledged // false)] | length)
  else 0 end
' "${TMP_DIR}/acked-show.json" 2>/dev/null || echo 0)

if [ "${ACKED_SHOWN}" -gt 0 ]; then
  ASSERT_ACK_SHOW="PASS"
  ok "assertion --show-acknowledged surfaces acks PASS (${ACKED_SHOWN} entries)"
else
  ASSERT_ACK_SHOW="FAIL"
  warn "--show-acknowledged surfaced 0 entries (schema may differ, see ${TMP_DIR}/acked-show.json)"
fi

# === Verdict ===
step "4. Verdict"

if [ "${REG_GATE}" = "FAIL" ] \
   && [ "${ASSERT_COUNT}" = "PASS" ] \
   && [ "${ASSERT_SIG}" = "PASS" ] \
   && [ "${ASSERT_SARIF}" = "PASS" ] \
   && [ "${ACKED_GATE}" = "PASS" ] \
   && [ "${ASSERT_ACK_ZERO}" = "PASS" ] \
   && [ "${ASSERT_ACK_SHOW}" = "PASS" ]; then
  verdict="PASS"
else
  verdict="FAIL"
fi

cat > "${REPORT}" <<EOF
# Scenario report: ${SCENARIO}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
perf-sentinel CLI image: ${IMAGE}
Trace fixture: ${TRACES_FIXTURE}

## Phase 1: clean baseline

- input: filtered fixture, fault-free traces only
- $(cat "${TMP_DIR}/clean-filter.log")
- analyzed: ${BASELINE_ANALYZED} findings
- gate: ${CLEAN_GATE}

## Phase 2: regression

- input: full fixture (149 traces, ~70 fault traces)
- analyzed: ${ANALYZED_COUNT} findings
- gate: ${REG_GATE} (FAIL expected)
- assertion >5 findings: ${ASSERT_COUNT}
- assertion signature on every finding (0.5.17): ${ASSERT_SIG} (${WITH_SIG}/${ANALYZED_COUNT})
- assertion SARIF schema: ${ASSERT_SARIF}

## Phase 3: ack workflow

- unique signatures extracted: ${SIG_COUNT}
- ack file: ${TMP_DIR}/.perf-sentinel-acknowledgments.toml (${ACK_BYTES} bytes)
- gate after ack: ${ACKED_GATE} (PASS expected)
- assertion 0 active findings: ${ASSERT_ACK_ZERO} (${ACTIVE_AFTER_ACK})
- assertion --show-acknowledged: ${ASSERT_ACK_SHOW} (${ACKED_SHOWN})

## Verdict: ${verdict}

EOF

if [ "${verdict}" = "PASS" ]; then
  color_green "ci-shift-left: PASS"
  cat "${REPORT}"
else
  color_red "ci-shift-left: FAIL"
  cat "${REPORT}"
  exit 1
fi
