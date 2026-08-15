#!/usr/bin/env bash
# chaos-replay capture (one-off): drive the upstream OpenTelemetry Astronomy
# Shop demo - via its own docker compose, OUTSIDE the lab k3d cluster -
# through a scripted CHAOS window, and produce the committed replay slice:
#
#   chaos-slice.ndjson   live telemetry of a system genuinely failing: real
#                        ERROR spans (flagd failure flags), structural
#                        half-traces (a mid-tier service SIGKILLed while its
#                        callees keep exporting), client timeouts (a paused
#                        service), flood traffic.
#
# The demo clone, the file-exporter injection and the stop/mv/start dump
# rotation rule are shared with scenarios/astronomy-shop/capture.sh (same
# pinned tag, same clone dir); chaos dumps land in gitignored
# artifacts/chaos-replay/. The manifest DRIVES the choreography
# (chaos.flags_enabled, chaos.kill, chaos.pause, chaos.window_minutes,
# traces) and gets the observed census stamped back (demo_version,
# otel_demo_commit, traces_analyzed, finding_census, error_spans,
# broken_parent_traces). Stamps are EXACT observed values (deterministic
# committed input + deterministic binary): any later drift fails verify.sh
# by design, restamping is a deliberate, reviewable act (rerun this script).
#
# Kill target rationale: checkout is a mid-tier orchestrator - SIGKILLing it
# loses its buffered spans while payment/shipping/currency/... still export
# their SERVER spans, whose parentSpanId now points at spans that never
# arrived. That is the broken-parent corpus a leaf-service kill cannot
# produce. The pause leg runs after checkout is back so its calls into the
# paused service actually happen (and time out).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEMO_TAG="${DEMO_TAG:-2.2.0}"
DEMO_REPO_URL="${DEMO_REPO_URL:-https://github.com/open-telemetry/opentelemetry-demo}"
WARMUP_SECONDS="${WARMUP_SECONDS:-60}"
FLAG_PROPAGATION_SECONDS="${FLAG_PROPAGATION_SECONDS:-30}"
EDGE_GUARD_SECONDS="${EDGE_GUARD_SECONDS:-30}"

ART="${REPO_ROOT}/artifacts/chaos-replay"
DEMO_DIR="${REPO_ROOT}/artifacts/astronomy-shop/otel-demo"   # shared clone
DUMP_DIR="${ART}/dump"
DUMP="${DUMP_DIR}/traces.ndjson"
OVERRIDE="${ART}/compose.file-exporter.yaml"
FIXTURES="${SCRIPT_DIR}/fixtures"
MANIFEST="${FIXTURES}/fixture-manifest.json"
SLICE="${FIXTURES}/chaos-slice.ndjson"
CURATE="${SCRIPT_DIR}/../astronomy-shop/curate.py"
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
  # Mirror the demo Makefile's launch (same as astronomy-shop/capture.sh):
  # both env files, plus the arm64/Darwin JVM workaround file when
  # applicable; DEMO_VERSION pinned from the shell (beats the env files).
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
for p in 8080 10000; do
  lsof -ti "tcp:${p}" >/dev/null 2>&1 \
    && die "port ${p} busy - the demo's frontend-proxy publishes it; free it first"
done
docker ps --format '{{.Names}}' | grep -q '^k3d-' \
  && warn "k3d lab cluster is running; the demo adds ~15-20 containers - stop it (make down) if Docker memory gets tight"

# The manifest drives the choreography. Validate it before touching Docker.
# Raw jq output is validated BEFORE any arithmetic touches it - $((null*60))
# under set -u aborts with a cryptic bash error instead of this die().
jq -e '.chaos.flags_enabled | length > 0' "${MANIFEST}" >/dev/null || die "chaos.flags_enabled empty in ${MANIFEST}"
KILL_SVC="$(jq -r '.chaos.kill.service // empty' "${MANIFEST}")"
KILL_AT="$(jq -r '.chaos.kill.at_offset_s' "${MANIFEST}")"
KILL_DOWN="$(jq -r '.chaos.kill.down_s' "${MANIFEST}")"
PAUSE_SVC="$(jq -r '.chaos.pause.service // empty' "${MANIFEST}")"
PAUSE_AT="$(jq -r '.chaos.pause.at_offset_s' "${MANIFEST}")"
PAUSE_S="$(jq -r '.chaos.pause.pause_s' "${MANIFEST}")"
WINDOW_MIN="$(jq -r '.chaos.window_minutes' "${MANIFEST}")"
SLICE_TRACES="$(jq -r '.traces' "${MANIFEST}")"
[ -n "${KILL_SVC}" ] && [ -n "${PAUSE_SVC}" ] \
  || die "chaos.kill.service / chaos.pause.service missing in ${MANIFEST}"
for v in "${KILL_AT}" "${KILL_DOWN}" "${PAUSE_AT}" "${PAUSE_S}" "${WINDOW_MIN}" "${SLICE_TRACES}"; do
  case "${v}" in *[!0-9]*|"") die "non-numeric choreography value in ${MANIFEST}" ;; esac
done
WINDOW_S="$((WINDOW_MIN * 60))"
[ "$((KILL_AT + KILL_DOWN))" -le "${PAUSE_AT}" ] || die "kill window overlaps pause window (manifest)"
[ "$((PAUSE_AT + PAUSE_S))" -lt "${WINDOW_S}" ] || die "pause window exceeds the capture window (manifest)"
ok "binary, docker compose, tools, ports free, choreography sane (window ${WINDOW_S}s)"

# ── workspace + demo clone at the pinned tag (shared with astronomy-shop) ────
step "Workspace + demo clone at ${DEMO_TAG}"
mkdir -p "${ART}"
rm -rf "${DUMP_DIR}"
mkdir -p "${DUMP_DIR}"
chmod 777 "${DUMP_DIR}"   # harmless at 2.2.0 (collector runs as 0:0), robust across tags
if [ -d "${DEMO_DIR}/.git" ]; then
  git -C "${DEMO_DIR}" describe --tags --exact-match 2>/dev/null | grep -Fqx "${DEMO_TAG}" \
    || die "stale demo clone (not at ${DEMO_TAG}) - rm -rf ${DEMO_DIR} and rerun"
  # Reset flags and the extras config from any previous capture (this
  # scenario's or astronomy-shop's).
  git -C "${DEMO_DIR}" checkout -- src/flagd/demo.flagd.json src/otel-collector/otelcol-config-extras.yml
  ok "reusing existing clone"
else
  git clone --depth 1 --branch "${DEMO_TAG}" "${DEMO_REPO_URL}" "${DEMO_DIR}" \
    || die "clone of ${DEMO_REPO_URL}@${DEMO_TAG} failed"
fi
OTEL_DEMO_COMMIT="$(git -C "${DEMO_DIR}" rev-parse HEAD)"
ok "demo at ${OTEL_DEMO_COMMIT}"

# Validate the manifest's flag names against the demo's flagd catalog NOW -
# the file exists right after the clone, no need to boot the demo (10+ min)
# to discover a typo'd flag.
FLAGD="${DEMO_DIR}/src/flagd/demo.flagd.json"
for f in $(jq -r '.chaos.flags_enabled[]' "${MANIFEST}"); do
  jq -e --arg f "$f" '.flags[$f]' "${FLAGD}" >/dev/null || die "unknown flagd flag: $f"
done
ok "flag names exist in the ${DEMO_TAG} flagd catalog"

step "Inject file exporter (extras config + compose volume override)"
# Same injection as astronomy-shop/capture.sh: otelcol-config-extras.yml is
# the demo's designed extension hook, and the collector config merge REPLACES
# arrays, so the tag's base traces exporters must be restated.
cat > "${DEMO_DIR}/src/otel-collector/otelcol-config-extras.yml" <<'EOF'
# Injected by scenarios/chaos-replay/capture.sh - NDJSON trace dump.
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
# Pull the released per-service images explicitly first: `up` BUILDS any
# service whose image is missing locally when a build: section exists (the
# pruned-image trap - local demo builds are not expected to work here).
# Only opensearch (a local config-wrapper image by design at this tag) has
# nothing to pull, --ignore-pull-failures lets it fall through to its build.
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
ok "demo warm"

# ── enable the chaos flags, then open a clean flagged window ─────────────────
step "Enable chaos flags: $(jq -r '.chaos.flags_enabled | join(", ")' "${MANIFEST}")"
for f in $(jq -r '.chaos.flags_enabled[]' "${MANIFEST}"); do
  # flagd fsnotify-watches the file: rewrite in place (cat) to keep the inode.
  jq --arg f "$f" '.flags[$f].defaultVariant = "on"' "${FLAGD}" > "${ART}/flagd.tmp"
  cat "${ART}/flagd.tmp" > "${FLAGD}"
  rm -f "${ART}/flagd.tmp"
done
sleep "${FLAG_PROPAGATION_SECONDS}"
# Rotate the dump so the slice window is 100% flagged traffic (discard
# warmup + propagation noise). Rotation rule: stop/mv/start only - the file
# exporter's fd is not guaranteed O_APPEND, never truncate the live dump.
dc stop otel-collector >/dev/null 2>&1 || die "collector stop failed"
rm -f "${DUMP}"
dc start otel-collector >/dev/null 2>&1 || die "collector start failed"
sleep 10
ok "flags on, dump rotated - chaos window starts now"

step "Chaos window (${WINDOW_S}s): kill ${KILL_SVC}@${KILL_AT}s for ${KILL_DOWN}s, pause ${PAUSE_SVC}@${PAUSE_AT}s for ${PAUSE_S}s"
sleep "${KILL_AT}"
color_yellow "    $(date +%T) SIGKILL ${KILL_SVC}"
dc kill "${KILL_SVC}" || die "docker compose kill ${KILL_SVC} failed"
sleep "${KILL_DOWN}"
color_yellow "    $(date +%T) restart ${KILL_SVC}"
dc start "${KILL_SVC}" || die "docker compose start ${KILL_SVC} failed"
dc ps "${KILL_SVC}" | grep -Eq "running|Up" || die "${KILL_SVC} did not come back after the kill leg"
sleep "$((PAUSE_AT - KILL_AT - KILL_DOWN))"
color_yellow "    $(date +%T) pause ${PAUSE_SVC}"
dc pause "${PAUSE_SVC}" || die "docker compose pause ${PAUSE_SVC} failed"
sleep "${PAUSE_S}"
color_yellow "    $(date +%T) unpause ${PAUSE_SVC}"
dc unpause "${PAUSE_SVC}" || die "docker compose unpause ${PAUSE_SVC} failed"
sleep "$((WINDOW_S - PAUSE_AT - PAUSE_S))"
dc stop otel-collector >/dev/null 2>&1 || die "collector stop failed"
[ -s "${DUMP}" ] || die "chaos dump empty - collector wrote nothing (cd ${DEMO_DIR} && docker compose logs otel-collector)"
mv "${DUMP}" "${ART}/chaos-full.ndjson"
ok "chaos-full.ndjson: $(wc -l < "${ART}/chaos-full.ndjson" | tr -d ' ') lines"

step "Demo down"
dc down -v >/dev/null 2>&1 || true

step "Curate a ${SLICE_TRACES}-trace slice (edge guard ${EDGE_GUARD_SECONDS}s)"
python3 "${CURATE}" "${ART}/chaos-full.ndjson" "${SLICE}" \
  --traces "${SLICE_TRACES}" --edge-guard "${EDGE_GUARD_SECONDS}" || die "curation failed"

# ── the slice must actually be chaotic (anti-vacuity, before stamping) ───────
step "Chaos census on the slice (error spans, broken-parent traces)"
SLICE_STATS="$(python3 "${SCRIPT_DIR}/chaos_census.py" slice "${SLICE}")" || die "chaos census failed"
ERR_SPANS="$(jq -r '.error_spans' <<< "${SLICE_STATS}")"
BROKEN="$(jq -r '.broken_parent_traces' <<< "${SLICE_STATS}")"
[ "${ERR_SPANS}" -gt 0 ] 2>/dev/null \
  || die "zero ERROR spans in the slice - the failure flags did not bite (check flagd propagation / lengthen the window)"
[ "${BROKEN}" -gt 0 ] 2>/dev/null \
  || die "zero broken-parent traces in the slice - the ${KILL_SVC} kill did not bite (lengthen down_s or kill during heavier load)"
ok "error_spans=${ERR_SPANS} broken_parent_traces=${BROKEN}"

step "Stamp manifest: analyze census with the local binary"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${SLICE}" --format json \
  > "${ART}/chaos-out.json" 2> "${ART}/chaos-err.txt" \
  || die "analyze on the chaos slice failed: $(tail -2 "${ART}/chaos-err.txt")"
FINDING_STATS="$(python3 "${SCRIPT_DIR}/chaos_census.py" findings "${ART}/chaos-out.json")" || die "finding census failed"
jq -e '.traces_analyzed > 0' <<< "${FINDING_STATS}" >/dev/null \
  || die "traces_analyzed=0 on the chaos slice - nothing survived ingest, look before stamping"
jq --arg v "${DEMO_TAG}" --arg c "${OTEL_DEMO_COMMIT}" \
   --argjson s "${SLICE_STATS}" --argjson f "${FINDING_STATS}" \
   '.demo_version = $v | .otel_demo_commit = $c
    | .error_spans = $s.error_spans | .broken_parent_traces = $s.broken_parent_traces
    | .traces_analyzed = $f.traces_analyzed | .finding_census = $f.finding_census' \
  "${MANIFEST}" > "${ART}/manifest.tmp" \
  && mv "${ART}/manifest.tmp" "${MANIFEST}" \
  || die "manifest stamp failed"
ok "demo_version=${DEMO_TAG} otel_demo_commit=${OTEL_DEMO_COMMIT}"
ok "census: $(jq -c '.finding_census' "${MANIFEST}") traces_analyzed=$(jq -r '.traces_analyzed' "${MANIFEST}")"

# ── self-check: the committed contract must hold on the fresh slice ──────────
step "Self-check: verify.sh on the curated slice"
"${SCRIPT_DIR}/verify.sh" || die "post-capture verify.sh self-check failed (see /tmp/scenario-chaos-replay-report.md)"

color_green "capture complete - review the census above, then: git add scenarios/chaos-replay/fixtures/"
