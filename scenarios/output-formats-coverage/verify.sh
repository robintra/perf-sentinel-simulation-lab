#!/usr/bin/env bash
# Output formats coverage, diff mode, signature presence, ack cap loader.
#
# 4 sub-tests run against artefacts produced by the ci-shift-left
# scenario (baseline-report.json, regression-report.json, regression.json):
#
#   6.A. Coverage of the 4 supported formats (text/json/sarif/html).
#        - text/json/sarif via `analyze --format`,
#        - html via `report` (the HTML emitter is a separate subcommand
#          in 0.5.17, not a flag on analyze).
#        Asserts every output is non-empty and well-formed, that JSON
#        and SARIF agree on the finding count, and that every JSON
#        finding carries a non-empty `signature` (0.5.17 feature).
#        SARIF signature presence is logged but does NOT fail the
#        scenario: the SARIF emitter does not include signature in 0.5.17,
#        a documented gap (memory item 10).
#        Markdown format is probed and expected to fail; the failure is
#        logged informationally (memory item 11).
#
#   6.B. Diff mode. Runs `perf-sentinel diff --before baseline --after
#        regression --format json` and asserts the output schema includes
#        `new_findings`, `resolved_findings`, `severity_changes`, and
#        `endpoint_metric_deltas`. Asserts new_findings count > 0 (the
#        regression introduced findings vs the baseline).
#
#   6.C. Cap loader. Generates a 17 MiB ack file (above the 16 MiB
#        cap from `crates/sentinel-core/src/acknowledgments.rs:30`) and
#        feeds it to analyze. Asserts analyze fails gracefully with a
#        clear error message about size, not a panic.
#
#   6.D. Quality gate clean. Sanity check that the gate accepts a clean
#        baseline (smoke test for the CLI plumbing).

set -euo pipefail

SCENARIO="output-formats-coverage"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"
CISL_DIR="/tmp/ci-shift-left"
CISL_CONFIG="${LAB_ROOT}/scenarios/ci-shift-left/.perf-sentinel.toml"

PERF_SENTINEL_VERSION="${PERF_SENTINEL_VERSION:-0.5.17}"
IMAGE="ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

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

[ -f "${CISL_DIR}/regression-traces.json" ] \
  || die "${CISL_DIR}/regression-traces.json missing, run 'make verify-ci-shift-left' first"
[ -f "${CISL_DIR}/baseline-traces.json" ] \
  || die "${CISL_DIR}/baseline-traces.json missing, run 'make verify-ci-shift-left' first"
[ -f "${CISL_DIR}/regression.json" ] \
  || die "${CISL_DIR}/regression.json missing, run 'make verify-ci-shift-left' first"

docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
ok "image ${IMAGE} available, ci-shift-left artefacts present"

# Stage everything inside TMP_DIR so docker run mounts a single
# directory. macOS Docker Desktop fails when a single file path is
# bind-mounted inside an already-mounted directory ("mountpoint outside
# of rootfs"). Same pattern used by ci-shift-left.
#
# source.json   = full fixture traces (input to analyze)
# baseline.json = filtered fixture (clean baseline traces)
cp "${CISL_DIR}/regression-traces.json" "${TMP_DIR}/source.json"
cp "${CISL_DIR}/baseline-traces.json"   "${TMP_DIR}/baseline.json"
cp "${CISL_DIR}/regression.json"        "${TMP_DIR}/cisl-regression.json"
cp "${CISL_CONFIG}"                     "${TMP_DIR}/.perf-sentinel.toml"

# === 6.A. Coverage formats supported + signature presence ===
step "6.A. Coverage of 4 supported formats + signature presence"

# analyze writes the chosen format to stdout (no --output flag), so
# every invocation redirects > to a file inside TMP_DIR.

# JSON
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format json \
  > "${TMP_DIR}/findings.json" 2> "${TMP_DIR}/analyze-json.log" \
  || die "analyze --format json failed, see ${TMP_DIR}/analyze-json.log"

# SARIF
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format sarif \
  > "${TMP_DIR}/findings.sarif" 2> "${TMP_DIR}/analyze-sarif.log" \
  || die "analyze --format sarif failed"

# Text (stdout)
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format text \
  > "${TMP_DIR}/findings.txt" 2> "${TMP_DIR}/analyze-text.log" \
  || warn "analyze --format text exited non-zero (gate may be tripping); see ${TMP_DIR}/findings.txt"

# HTML via separate `report` subcommand
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  report --input /workdir/source.json --output /workdir/findings.html \
  > "${TMP_DIR}/report-html.log" 2>&1 \
  || die "report --output html failed, see ${TMP_DIR}/report-html.log"

# All 4 outputs non-empty
JSON_BYTES=$(wc -c < "${TMP_DIR}/findings.json")
SARIF_BYTES=$(wc -c < "${TMP_DIR}/findings.sarif")
TEXT_BYTES=$(wc -c < "${TMP_DIR}/findings.txt")
HTML_BYTES=$(wc -c < "${TMP_DIR}/findings.html")
ok "format sizes: json=${JSON_BYTES}B sarif=${SARIF_BYTES}B text=${TEXT_BYTES}B html=${HTML_BYTES}B"

if [ "${JSON_BYTES}" -gt 0 ] && [ "${SARIF_BYTES}" -gt 0 ] \
   && [ "${TEXT_BYTES}" -gt 0 ] && [ "${HTML_BYTES}" -gt 1024 ]; then
  ASSERT_FORMATS="PASS"
  ok "assertion 4 formats produce non-empty output PASS"
else
  ASSERT_FORMATS="FAIL"
  warn "one or more formats empty"
fi

# Coherence: JSON findings count == SARIF results count
JSON_COUNT=$(jq '.findings | length' "${TMP_DIR}/findings.json")
SARIF_COUNT=$(jq '.runs[0].results | length' "${TMP_DIR}/findings.sarif")
if [ "${JSON_COUNT}" = "${SARIF_COUNT}" ] && [ "${JSON_COUNT}" -gt 0 ]; then
  ASSERT_COHERENCE="PASS"
  ok "assertion JSON/SARIF agree on count PASS (${JSON_COUNT})"
else
  ASSERT_COHERENCE="FAIL"
  warn "JSON ${JSON_COUNT} vs SARIF ${SARIF_COUNT} disagreement"
fi

# Signature presence in JSON: every finding has non-empty signature
JSON_WITH_SIG=$(jq '[.findings[] | select(.signature != null and .signature != "")] | length' \
  "${TMP_DIR}/findings.json")
if [ "${JSON_WITH_SIG}" = "${JSON_COUNT}" ] && [ "${JSON_COUNT}" -gt 0 ]; then
  ASSERT_SIG_JSON="PASS"
  ok "assertion signature on every JSON finding PASS"
else
  ASSERT_SIG_JSON="FAIL"
  warn "JSON signature: ${JSON_WITH_SIG}/${JSON_COUNT} populated"
fi

# Signature presence in SARIF: probe properties.signature OR
# fingerprints["perfsentinel/v1"]. Logged informationally, NOT fail.
SARIF_WITH_SIG=$(jq '
  [.runs[0].results[] |
    (.properties.signature // .fingerprints["perfsentinel/v1"] // empty)
  ] | length
' "${TMP_DIR}/findings.sarif" 2>/dev/null || echo 0)

if [ "${SARIF_WITH_SIG}" -gt 0 ]; then
  SIG_SARIF_NOTE="present (${SARIF_WITH_SIG}/${SARIF_COUNT})"
  ok "SARIF signature ${SIG_SARIF_NOTE} - upstream may have closed memory item 10"
else
  SIG_SARIF_NOTE="absent (gap, memory item 10)"
  warn "SARIF signature absent in 0.5.17 (known gap, see memory item 10)"
fi

# Markdown format: expect failure with clear error.
docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze --input /workdir/source.json --format markdown \
  > "${TMP_DIR}/markdown-stdout.log" 2> "${TMP_DIR}/markdown-stderr.log" \
  && MD_EXIT=0 || MD_EXIT=$?
if [ "${MD_EXIT}" -ne 0 ]; then
  MARKDOWN_NOTE="rejected as expected (exit ${MD_EXIT}, gap memory item 11)"
  ok "markdown format rejected as expected"
else
  MARKDOWN_NOTE="accepted (upstream may have shipped markdown support, close memory item 11)"
  ok "markdown format accepted - upstream may have closed memory item 11"
fi

# === 6.B. Diff mode ===
step "6.B. Diff mode (--before baseline, --after regression)"

docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  diff \
  --before /workdir/baseline.json \
  --after /workdir/source.json \
  --format json \
  --output /workdir/diff.json \
  > "${TMP_DIR}/diff.log" 2>&1 \
  && DIFF_EXIT=0 || DIFF_EXIT=$?

if [ ! -s "${TMP_DIR}/diff.json" ]; then
  warn "diff produced no output (exit ${DIFF_EXIT}), see ${TMP_DIR}/diff.log"
  ASSERT_DIFF_SCHEMA="FAIL"
  ASSERT_DIFF_NEW="FAIL"
  NEW_FINDINGS=0
else
  # Validate schema: new_findings, resolved_findings, severity_changes,
  # endpoint_metric_deltas all present.
  if jq -e 'has("new_findings") and has("resolved_findings") and has("severity_changes") and has("endpoint_metric_deltas")' \
     "${TMP_DIR}/diff.json" >/dev/null; then
    ASSERT_DIFF_SCHEMA="PASS"
    ok "diff schema PASS (4 expected fields present)"
  else
    ASSERT_DIFF_SCHEMA="FAIL"
    warn "diff JSON missing one of the 4 expected fields, see ${TMP_DIR}/diff.json"
  fi

  NEW_FINDINGS=$(jq '.new_findings | length' "${TMP_DIR}/diff.json" 2>/dev/null || echo 0)
  if [ "${NEW_FINDINGS}" -gt 0 ]; then
    ASSERT_DIFF_NEW="PASS"
    ok "diff identified ${NEW_FINDINGS} new findings vs baseline"
  else
    ASSERT_DIFF_NEW="FAIL"
    warn "diff identified 0 new findings (regression introduced no new diff signals)"
  fi
fi

# === 6.C. Cap loader 16 MiB on ack file ===
step "6.C. Ack file cap loader (>16 MiB rejected)"

# Generate ~17 MiB of valid-ish TOML.
{
  printf '# B1 6.C: oversized ack file (>16 MiB) to validate cap loader\n'
  for i in $(seq 1 100000); do
    cat <<EOF

[[acknowledged]]
signature = "test_type:test_service:test_endpoint:$(printf '%016x' "${i}")"
acknowledged_by = "test"
acknowledged_at = "2026-05-02"
reason = "padding-iter-${i}-$(printf '%0150d' "${i}")"
EOF
  done
} > "${TMP_DIR}/oversized-acks.toml"

if [ "$(uname -s)" = "Linux" ]; then
  ACTUAL_SIZE=$(stat -c%s "${TMP_DIR}/oversized-acks.toml")
else
  ACTUAL_SIZE=$(stat -f%z "${TMP_DIR}/oversized-acks.toml")
fi
ok "generated ack file: ${ACTUAL_SIZE} bytes"

if [ "${ACTUAL_SIZE}" -le 16777216 ]; then
  warn "ack file only ${ACTUAL_SIZE} bytes (<= 16 MiB), the test will not exercise the cap"
fi

docker run --rm "${DOCKER_NET_FLAGS[@]}" -v "${TMP_DIR}:/workdir" "${IMAGE}" \
  analyze \
  --input /workdir/source.json \
  --acknowledgments /workdir/oversized-acks.toml \
  --format json \
  > "${TMP_DIR}/oversized-stdout.log" 2> "${TMP_DIR}/oversized-stderr.log" \
  && CAP_EXIT=0 || CAP_EXIT=$?

if [ "${CAP_EXIT}" -ne 0 ]; then
  ok "analyze rejected oversized ack file (exit ${CAP_EXIT})"
  if grep -qiE 'too large|cap|16.*MiB|MAX_ACKNOWLEDGMENTS|TooLarge|exceeds' \
     "${TMP_DIR}/oversized-stderr.log" "${TMP_DIR}/oversized-stdout.log"; then
    ASSERT_CAP="PASS"
    ok "assertion cap loader fail message clear PASS"
  else
    ASSERT_CAP="FAIL"
    warn "rejected but error message unclear, see ${TMP_DIR}/oversized-stderr.log"
  fi
else
  ASSERT_CAP="FAIL"
  warn "analyze accepted oversized ack file (cap loader broken)"
fi

# === 6.D. Sanity: clean gate ===
step "6.D. Sanity: gate on clean baseline"

docker run --rm "${DOCKER_NET_FLAGS[@]}" \
  -v "${TMP_DIR}:/workdir" \
  "${IMAGE}" analyze \
  --input /workdir/baseline.json \
  --config /workdir/.perf-sentinel.toml \
  --ci \
  > "${TMP_DIR}/sanity-stdout.log" 2> "${TMP_DIR}/sanity.log" \
  && SANITY_EXIT=0 || SANITY_EXIT=$?

if [ "${SANITY_EXIT}" -eq 0 ]; then
  ASSERT_SANITY="PASS"
  ok "clean gate PASS (sanity)"
else
  ASSERT_SANITY="WARN"
  warn "clean gate failed exit ${SANITY_EXIT} (residue findings on long-lived cluster)"
fi

# === Verdict ===
step "7. Verdict"

# 6.D is informational; the 5 hard assertions are A formats coherence,
# A signature in JSON, B diff schema + new_findings, C cap loader.
if [ "${ASSERT_FORMATS}" = "PASS" ] \
   && [ "${ASSERT_COHERENCE}" = "PASS" ] \
   && [ "${ASSERT_SIG_JSON}" = "PASS" ] \
   && [ "${ASSERT_DIFF_SCHEMA}" = "PASS" ] \
   && [ "${ASSERT_DIFF_NEW}" = "PASS" ] \
   && [ "${ASSERT_CAP}" = "PASS" ]; then
  verdict="PASS"
else
  verdict="FAIL"
fi

cat > "${REPORT}" <<EOF
# Scenario report: ${SCENARIO}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
perf-sentinel CLI image: ${IMAGE}
Source artefacts: ${CISL_DIR}/

## 6.A. Coverage of 4 formats + signature presence

| Format | Bytes | Source command |
| --- | --- | --- |
| json  | ${JSON_BYTES}  | analyze --format json (stdout) |
| sarif | ${SARIF_BYTES} | analyze --format sarif (stdout) |
| text  | ${TEXT_BYTES}  | analyze --format text (stdout) |
| html  | ${HTML_BYTES}  | report --input --output (separate subcommand) |

Coherence (JSON count == SARIF count): ${ASSERT_COHERENCE} (${JSON_COUNT}/${SARIF_COUNT})
Signature on every JSON finding: ${ASSERT_SIG_JSON} (${JSON_WITH_SIG}/${JSON_COUNT})
Signature in SARIF (informational, gap memory item 10): ${SIG_SARIF_NOTE}
Markdown format (informational, gap memory item 11): ${MARKDOWN_NOTE}

## 6.B. Diff mode

Schema completeness (new/resolved/severity_changes/endpoint_metric_deltas): ${ASSERT_DIFF_SCHEMA}
new_findings count > 0: ${ASSERT_DIFF_NEW} (${NEW_FINDINGS})

## 6.C. Cap loader

Generated ack file: ${ACTUAL_SIZE} bytes
Cap loader rejection: ${ASSERT_CAP}

## 6.D. Sanity gate clean (informational)

${ASSERT_SANITY}

## Verdict: ${verdict}

EOF

if [ "${verdict}" = "PASS" ]; then
  color_green "output-formats-coverage: PASS"
  cat "${REPORT}"
else
  color_red "output-formats-coverage: FAIL"
  cat "${REPORT}"
  exit 1
fi
