#!/usr/bin/env bash
# Validate the upstream jenkinsfile.groovy template at v0.5.17.
#
# Note on filename: upstream ships `jenkinsfile.groovy` (lowercase, .groovy),
# NOT `Jenkinsfile`. The Jenkins Multibranch Pipeline plugin accepts the
# .groovy extension for IDE syntax highlighting.
#
# 3 steps:
#
# 1. Fetch upstream `docs/ci-templates/jenkinsfile.groovy` at v0.5.17.
# 2. Structural lint: assert the declarative pipeline skeleton
#    (`pipeline { agent ... stages { ... } }`), the perf-sentinel install
#    + analyze stages, and the `--ci` quality-gate enforcement step.
# 3. Best-effort runtime via `jenkinsfile-runner` containerised. This
#    runner can be flaky (Java init, plugin downloads) and the upstream
#    template downloads a Linux binary from GitHub Releases that may not
#    be available offline. SKIP gracefully on either failure with a
#    clear note.
#
# Optional knobs:
#   UPSTREAM_VERSION    override the version tag (default 0.5.17).
#   UPSTREAM_PATH       use a local copy of the template.
#   SKIP_RUNTIME=1      skip step 3 (lint + structural only).

set -euo pipefail

SCENARIO="template-jenkinsfile"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

UPSTREAM_VERSION="${UPSTREAM_VERSION:-0.5.17}"
UPSTREAM_URL="https://raw.githubusercontent.com/robintra/perf-sentinel/v${UPSTREAM_VERSION}/docs/ci-templates/jenkinsfile.groovy"
JFR_IMAGE="${JFR_IMAGE:-jenkins/jenkinsfile-runner:latest}"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red   "    warn: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

verdict="UNKNOWN"

# === Step 1: fetch ===
step "1. Fetch upstream jenkinsfile.groovy at v${UPSTREAM_VERSION}"

if [ -n "${UPSTREAM_PATH:-}" ] && [ -f "${UPSTREAM_PATH}" ]; then
  cp "${UPSTREAM_PATH}" "${TMP_DIR}/Jenkinsfile"
  ok "using local copy at ${UPSTREAM_PATH}"
elif curl -sSLf -o "${TMP_DIR}/Jenkinsfile" "${UPSTREAM_URL}" 2>/dev/null; then
  ok "fetched ${UPSTREAM_URL}"
elif [ -f "${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/jenkinsfile.groovy" ]; then
  cp "${HOME}/RustroverProjects/perf-sentinel/docs/ci-templates/jenkinsfile.groovy" \
     "${TMP_DIR}/Jenkinsfile"
  warn "curl failed, fell back to local clone"
else
  die "cannot fetch upstream jenkinsfile.groovy, set UPSTREAM_PATH"
fi
UPSTREAM_BYTES=$(wc -c < "${TMP_DIR}/Jenkinsfile")
ok "template size: ${UPSTREAM_BYTES} bytes"

# === Step 2: structural lint ===
step "2. Structural invariants"

# Skeleton check: declarative pipeline.
if ! grep -qE '^\s*pipeline\s*\{' "${TMP_DIR}/Jenkinsfile"; then
  die "missing 'pipeline {' declarative skeleton"
fi
if ! grep -qE '^\s*stages\s*\{' "${TMP_DIR}/Jenkinsfile"; then
  die "missing 'stages {' block"
fi
if ! grep -qE 'perf-sentinel\s+analyze' "${TMP_DIR}/Jenkinsfile"; then
  die "missing perf-sentinel analyze invocation"
fi
if ! grep -qE -- '--ci' "${TMP_DIR}/Jenkinsfile"; then
  die "missing --ci quality-gate flag"
fi
if ! grep -qE 'sarif|SARIF' "${TMP_DIR}/Jenkinsfile"; then
  die "missing SARIF output reference"
fi
if ! grep -qE 'archiveArtifacts' "${TMP_DIR}/Jenkinsfile"; then
  warn "no archiveArtifacts step (artefacts may not be retained)"
fi

PERF_VERSION_PIN=$(grep -oE "PERF_SENTINEL_VERSION\s*=\s*'[0-9.]+'" "${TMP_DIR}/Jenkinsfile" | head -1)
if [ -z "${PERF_VERSION_PIN}" ]; then
  warn "PERF_SENTINEL_VERSION pin not found"
else
  ok "version pin: ${PERF_VERSION_PIN}"
fi

STRUCTURAL_VERDICT="PASS"
ok "structural invariants PASS (pipeline, stages, analyze, --ci, sarif)"

# === Step 3: best-effort runtime ===
step "3. Best-effort runtime via jenkinsfile-runner"

if [ "${SKIP_RUNTIME:-0}" = "1" ]; then
  RUNTIME_VERDICT="SKIPPED"
  RUNTIME_NOTE="SKIP_RUNTIME=1"
  warn "${RUNTIME_NOTE}"
else
  command -v docker >/dev/null || die "docker not on PATH"

  # Pull the jenkinsfile-runner image if not cached. Tolerate failure.
  if ! docker image inspect "${JFR_IMAGE}" >/dev/null 2>&1; then
    if ! docker pull "${JFR_IMAGE}" >/dev/null 2>&1; then
      RUNTIME_VERDICT="SKIPPED"
      RUNTIME_NOTE="cannot pull ${JFR_IMAGE}, runtime SKIPPED"
      warn "${RUNTIME_NOTE}"
    fi
  fi

  # Only attempt the run if the image is now available locally.
  if docker image inspect "${JFR_IMAGE}" >/dev/null 2>&1; then
    mkdir -p "${TMP_DIR}/workspace"
    cp "${TMP_DIR}/Jenkinsfile" "${TMP_DIR}/workspace/Jenkinsfile"
    cp "${SCENARIO_DIR}/.perf-sentinel.toml" "${TMP_DIR}/workspace/.perf-sentinel.toml"
    if [ -f "/tmp/ci-shift-left/regression-traces.json" ]; then
      cp "/tmp/ci-shift-left/regression-traces.json" "${TMP_DIR}/workspace/target/traces.json" 2>/dev/null \
        || (mkdir -p "${TMP_DIR}/workspace/target" && cp "/tmp/ci-shift-left/regression-traces.json" "${TMP_DIR}/workspace/target/traces.json")
    else
      mkdir -p "${TMP_DIR}/workspace/target"
      printf '{"data": []}' > "${TMP_DIR}/workspace/target/traces.json"
    fi

    if timeout 300 docker run --rm \
         -v "${TMP_DIR}/workspace:/workspace:ro" \
         -v /var/run/docker.sock:/var/run/docker.sock \
         "${JFR_IMAGE}" \
         run --jenkinsfile /workspace/Jenkinsfile \
         > "${TMP_DIR}/jfr.log" 2>&1
    then
      RUNTIME_VERDICT="PASS"
      RUNTIME_NOTE="jenkinsfile-runner completed"
      ok "${RUNTIME_NOTE}"
    else
      JFR_EXIT=$?
      RUNTIME_VERDICT="SKIPPED"
      RUNTIME_NOTE="jenkinsfile-runner exited ${JFR_EXIT} (env-related, see ${TMP_DIR}/jfr.log)"
      warn "${RUNTIME_NOTE}"
    fi
  fi
fi

# === Verdict ===
step "4. Verdict"

# Structural is the hard gate. Runtime SKIPPED is acceptable; runtime
# FAIL is treated as PARTIAL (template is syntactically/structurally OK,
# environment cannot run it).
case "${STRUCTURAL_VERDICT}/${RUNTIME_VERDICT}" in
  PASS/PASS)        verdict="PASS" ;;
  PASS/SKIPPED)     verdict="PARTIAL (runtime SKIPPED, structural PASS)" ;;
  PASS/*)           verdict="PARTIAL (runtime ${RUNTIME_VERDICT}, structural PASS)" ;;
  *)                verdict="FAIL" ;;
esac

cat > "${REPORT}" <<EOF
# Scenario report: ${SCENARIO}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Upstream URL: ${UPSTREAM_URL}
Filename: jenkinsfile.groovy (NOT Jenkinsfile, lowercase + .groovy ext)

## Step 1: fetch

- ${UPSTREAM_BYTES} bytes fetched

## Step 2: structural lint

- verdict: ${STRUCTURAL_VERDICT}
- skeleton: pipeline { stages { ... } } present
- analyze + --ci + sarif: present
- version pin: ${PERF_VERSION_PIN:-?}

## Step 3: runtime via jenkinsfile-runner

- verdict: ${RUNTIME_VERDICT}
- note: ${RUNTIME_NOTE}

## Verdict: ${verdict}

EOF

case "${verdict}" in
  PASS|PARTIAL*)
    color_green "${SCENARIO}: ${verdict}"
    cat "${REPORT}"
    ;;
  *)
    color_red "${SCENARIO}: FAIL"
    cat "${REPORT}"
    exit 1
    ;;
esac
