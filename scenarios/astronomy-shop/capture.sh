#!/usr/bin/env bash
# astronomy-shop capture (one-off): run the upstream OpenTelemetry Astronomy
# Shop demo via its own docker compose - OUTSIDE the lab k3d cluster - with a
# Collector file exporter, and produce the two committed replay slices:
#
#   clean-slice.ndjson     all feature flags off, normal load-generator
#                          traffic: the false-positive corpus.
#   degraded-slice.ndjson  the manifest's flags_enabled turned on: the
#                          recall corpus.
#
# Full dumps land in artifacts/astronomy-shop/ (gitignored); only the curated
# slices and the stamped fixture-manifest.json are meant to be committed.
# The manifest DRIVES the capture: flags_enabled is read from it, and
# demo_version / otel_demo_commit / fp_budget are stamped back into it.
# fp_budget is the exact observed finding count on the curated clean slice
# (deterministic input + deterministic binary, so no slack factor): any later
# binary exceeding it fails verify.sh F1 by design.
#
# Rotation rule: the file exporter buffers and its fd is not guaranteed
# O_APPEND, so the live dump is never truncated from the host. Phases are cut
# by stop/mv/start of the collector (clean shutdown flushes and closes).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEMO_TAG="${DEMO_TAG:-2.2.0}"
DEMO_REPO_URL="${DEMO_REPO_URL:-https://github.com/open-telemetry/opentelemetry-demo}"
CLEAN_MINUTES="${CLEAN_MINUTES:-10}"
DEGRADED_MINUTES="${DEGRADED_MINUTES:-10}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
FLAG_PROPAGATION_SECONDS="${FLAG_PROPAGATION_SECONDS:-30}"
SLICE_TRACES="${SLICE_TRACES:-300}"
EDGE_GUARD_SECONDS="${EDGE_GUARD_SECONDS:-30}"

ART="${REPO_ROOT}/artifacts/astronomy-shop"
DEMO_DIR="${ART}/otel-demo"
DUMP_DIR="${ART}/dump"
DUMP="${DUMP_DIR}/traces.ndjson"
OVERRIDE="${ART}/compose.file-exporter.yaml"
FIXTURES="${SCRIPT_DIR}/fixtures"
MANIFEST="${FIXTURES}/fixture-manifest.json"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_yellow "    warn: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

dc() {
  # Mirror the demo Makefile's launch: both env files, plus the arm64/Darwin
  # JVM workaround file (JDK-8345296) when applicable. The tag's .env ships
  # DEMO_VERSION=latest; pin it to the released per-service images
  # (ghcr.io/open-telemetry/demo:<tag>-<service>) - shell env beats env files.
  local env_flags=(--env-file "${DEMO_DIR}/.env" --env-file "${DEMO_DIR}/.env.override")
  [ "$(uname -s)/$(uname -m)" = "Darwin/arm64" ] \
    && env_flags+=(--env-file "${DEMO_DIR}/.env.arm64")
  DEMO_VERSION="${DEMO_TAG}" docker compose --project-directory "${DEMO_DIR}" "${env_flags[@]}" \
    -f "${DEMO_DIR}/docker-compose.yml" -f "${OVERRIDE}" "$@"
}

step "Preflight"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || die "Docker unavailable"
docker compose version >/dev/null 2>&1 || die "docker compose v2 required"
for c in jq python3 git curl lsof; do command -v "$c" >/dev/null 2>&1 || die "$c required"; done
[ -s "${MANIFEST}" ] || die "missing ${MANIFEST}"
jq -e '.flags_enabled | length > 0' "${MANIFEST}" >/dev/null || die "flags_enabled empty in ${MANIFEST}"
for p in 8080 10000; do
  lsof -ti "tcp:${p}" >/dev/null 2>&1 \
    && die "port ${p} busy - the demo's frontend-proxy publishes it; free it first"
done
docker ps --format '{{.Names}}' | grep -q '^k3d-' \
  && warn "k3d lab cluster is running; the demo adds ~15-20 containers - stop it (make down) if Docker memory gets tight"
ok "binary, docker compose, jq, python3, git, lsof, ports 8080/10000 free"

step "Workspace + demo clone at ${DEMO_TAG}"
mkdir -p "${ART}"
rm -rf "${DUMP_DIR}"
mkdir -p "${DUMP_DIR}"
chmod 777 "${DUMP_DIR}"   # harmless at 2.2.0 (collector runs as 0:0), robust across tags
if [ -d "${DEMO_DIR}/.git" ]; then
  git -C "${DEMO_DIR}" describe --tags --exact-match 2>/dev/null | grep -Fqx "${DEMO_TAG}" \
    || die "stale demo clone (not at ${DEMO_TAG}) - rm -rf ${DEMO_DIR} and rerun"
  # Reset flags and the extras config from any aborted previous run.
  git -C "${DEMO_DIR}" checkout -- src/flagd/demo.flagd.json src/otel-collector/otelcol-config-extras.yml
  ok "reusing existing clone"
else
  git clone --depth 1 --branch "${DEMO_TAG}" "${DEMO_REPO_URL}" "${DEMO_DIR}" \
    || die "clone of ${DEMO_REPO_URL}@${DEMO_TAG} failed"
fi
OTEL_DEMO_COMMIT="$(git -C "${DEMO_DIR}" rev-parse HEAD)"
ok "demo at ${OTEL_DEMO_COMMIT}"

step "Inject file exporter (extras config + compose volume override)"
# otelcol-config-extras.yml is the demo's designed extension hook, merged
# second on the collector command line. Collector config merge REPLACES
# arrays: the exporter list below must restate the tag's base traces
# exporters (otlp -> jaeger, debug, and the spanmetrics connector - dropping
# spanmetrics leaves the connector unconsumed and the collector fails
# pipeline validation).
cat > "${DEMO_DIR}/src/otel-collector/otelcol-config-extras.yml" <<'EOF'
# Injected by scenarios/astronomy-shop/capture.sh - NDJSON trace dump.
exporters:
  file/traces:
    path: /out/traces.ndjson

service:
  pipelines:
    traces:
      exporters: [otlp, debug, spanmetrics, file/traces]
EOF
cat > "${OVERRIDE}" <<EOF
services:
  otel-collector:
    volumes:
      - ${DUMP_DIR}:/out
EOF
ok "extras config + ${OVERRIDE}"

trap 'dc down -v >/dev/null 2>&1 || true' EXIT

step "Demo up (pulls ghcr.io images on first run) + warmup ${WARMUP_SECONDS}s"
# No --no-build: opensearch is build-only at this tag (a local config wrapper
# image); everything else pulls its released ghcr image and is never rebuilt.
# Pull explicitly first: `up` BUILDS any service whose image is missing
# locally when a build: section exists (the pruned-image trap - local demo
# builds are not expected to work here); --ignore-pull-failures lets
# opensearch fall through to its build.
dc pull --ignore-pull-failures > "${ART}/pull.log" 2>&1 \
  || warn "some images did not pull (see ${ART}/pull.log) - compose may try to build them"
dc up -d || die "docker compose up failed"
ready=0
for _ in $(seq 1 120); do
  curl -fsS -o /dev/null "http://localhost:8080" 2>/dev/null && { ready=1; break; }
  sleep 5
done
[ "${ready}" = "1" ] || die "frontend-proxy not answering on :8080 after 10min: $(dc ps 2>/dev/null | tail -5)"
sleep "${WARMUP_SECONDS}"
# Discard warmup noise (Locust ramp, JVM first requests): rotate the dump.
dc stop otel-collector >/dev/null 2>&1 || die "collector stop failed"
rm -f "${DUMP}"
dc start otel-collector >/dev/null 2>&1 || die "collector start failed"
sleep 10
ok "demo warm, dump rotated"

# ── clean phase (false-positive corpus) ──────────────────────────────────────
step "Clean phase: ${CLEAN_MINUTES}min of default traffic, all flags off"
sleep "$((CLEAN_MINUTES * 60))"
dc stop otel-collector >/dev/null 2>&1 || die "collector stop failed"
[ -s "${DUMP}" ] || die "clean dump empty - collector wrote nothing (docker compose logs otel-collector)"
mv "${DUMP}" "${ART}/clean-full.ndjson"
ok "clean-full.ndjson: $(wc -l < "${ART}/clean-full.ndjson" | tr -d ' ') lines"

# ── enable the manifest's flags (collector stays down through the switch) ───
step "Enable flags from the manifest: $(jq -r '.flags_enabled | join(", ")' "${MANIFEST}")"
FLAGD="${DEMO_DIR}/src/flagd/demo.flagd.json"
for f in $(jq -r '.flags_enabled[]' "${MANIFEST}"); do
  jq -e --arg f "$f" '.flags[$f]' "${FLAGD}" >/dev/null || die "unknown flagd flag: $f"
  # flagd fsnotify-watches the file: rewrite in place (cat) to keep the inode.
  jq --arg f "$f" '.flags[$f].defaultVariant = "on"' "${FLAGD}" > "${ART}/flagd.tmp"
  cat "${ART}/flagd.tmp" > "${FLAGD}"
  rm -f "${ART}/flagd.tmp"
done
sleep "${FLAG_PROPAGATION_SECONDS}"

# ── degraded phase (recall corpus) ───────────────────────────────────────────
step "Degraded phase: ${DEGRADED_MINUTES}min with the flags on"
dc start otel-collector >/dev/null 2>&1 || die "collector start failed"
sleep 10
sleep "$((DEGRADED_MINUTES * 60))"
dc stop otel-collector >/dev/null 2>&1 || die "collector stop failed"
[ -s "${DUMP}" ] || die "degraded dump empty - collector wrote nothing (docker compose logs otel-collector)"
mv "${DUMP}" "${ART}/degraded-full.ndjson"
ok "degraded-full.ndjson: $(wc -l < "${ART}/degraded-full.ndjson" | tr -d ' ') lines"

step "Demo down"
dc down -v >/dev/null 2>&1 || true

step "Curate ${SLICE_TRACES}-trace slices (edge guard ${EDGE_GUARD_SECONDS}s)"
python3 "${SCRIPT_DIR}/curate.py" "${ART}/clean-full.ndjson" "${FIXTURES}/clean-slice.ndjson" \
  --traces "${SLICE_TRACES}" --edge-guard "${EDGE_GUARD_SECONDS}" || die "clean curation failed"
python3 "${SCRIPT_DIR}/curate.py" "${ART}/degraded-full.ndjson" "${FIXTURES}/degraded-slice.ndjson" \
  --traces "${SLICE_TRACES}" --edge-guard "${EDGE_GUARD_SECONDS}" || die "degraded curation failed"

step "Stamp manifest: fp_budget from the observed clean-slice finding count"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIXTURES}/clean-slice.ndjson" --format json \
  > "${ART}/clean-out.json" 2> "${ART}/clean-err.txt" \
  || die "analyze on the clean slice failed: $(tail -2 "${ART}/clean-err.txt")"
FP_BUDGET="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get("findings", [])
print(len(items))' "${ART}/clean-out.json")" || die "could not read finding count from clean-out.json"
jq --arg v "${DEMO_TAG}" --arg c "${OTEL_DEMO_COMMIT}" --argjson b "${FP_BUDGET}" \
  '.demo_version = $v | .otel_demo_commit = $c | .fp_budget = $b' \
  "${MANIFEST}" > "${ART}/manifest.tmp" \
  && mv "${ART}/manifest.tmp" "${MANIFEST}" \
  || die "manifest stamp failed (fp_budget=${FP_BUDGET:-empty})"
ok "demo_version=${DEMO_TAG} otel_demo_commit=${OTEL_DEMO_COMMIT} fp_budget=${FP_BUDGET}"

# ── self-check: the committed contract must hold on the fresh slices ─────────
step "Self-check: verify.sh on the curated slices"
"${SCRIPT_DIR}/verify.sh" || die "post-capture verify.sh self-check failed (see /tmp/scenario-astronomy-shop-report.md)"

color_green "capture complete - review the census above, then: git add scenarios/astronomy-shop/fixtures/"
