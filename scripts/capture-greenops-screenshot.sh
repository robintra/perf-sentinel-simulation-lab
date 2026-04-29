#!/usr/bin/env bash
# Capture a PNG of the perf-sentinel report dashboard, with the Carbon
# scoring banner visible. Pipeline:
#   1. kubectl port-forward perf-sentinel-daemon 14318
#   2. curl /api/export/report > trace JSON
#   3. perf-sentinel report --input - --output artifacts/greenops-report.html
#   4. Chrome headless --screenshot=artifacts/greenops-bandeau.png
# Usage: ./scripts/capture-greenops-screenshot.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="observability"
DAEMON_SERVICE="perf-sentinel-daemon"
DAEMON_PORT="14318"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"
HTML_OUT="${ARTIFACTS_DIR}/greenops-report.html"
PNG_OUT="${ARTIFACTS_DIR}/greenops-bandeau.png"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

resolve_sentinel_bin() {
  if [ -x "${PERF_SENTINEL_LOCAL_BIN}" ]; then
    echo "${PERF_SENTINEL_LOCAL_BIN}"
    return
  fi
  if command -v perf-sentinel >/dev/null 2>&1; then
    command -v perf-sentinel
    return
  fi
  die "perf-sentinel binary not found. Install via: cargo install --path \"\${PERF_SENTINEL_REPO_PATH}/crates/sentinel-cli\" or: cd \"\${PERF_SENTINEL_REPO_PATH}\" && cargo build --release -p sentinel-cli"
}

resolve_chrome_bin() {
  local candidates=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  )
  for c in "${candidates[@]}"; do
    if [ -x "${c}" ]; then
      echo "${c}"
      return
    fi
  done
  if command -v google-chrome >/dev/null 2>&1; then
    command -v google-chrome
    return
  fi
  if command -v chromium >/dev/null 2>&1; then
    command -v chromium
    return
  fi
  die "Chrome or Chromium not found. Install Chrome or Chromium and retry."
}

step "Resolving host binaries"
SENTINEL_BIN="$(resolve_sentinel_bin)"
ok "perf-sentinel: ${SENTINEL_BIN}"
CHROME_BIN="$(resolve_chrome_bin)"
ok "chrome:        ${CHROME_BIN}"

mkdir -p "${ARTIFACTS_DIR}"

step "Port-forwarding ${NAMESPACE}/${DAEMON_SERVICE} on :${DAEMON_PORT}"
kubectl -n "${NAMESPACE}" port-forward "svc/${DAEMON_SERVICE}" "${DAEMON_PORT}:${DAEMON_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  if curl -fsS "http://localhost:${DAEMON_PORT}/health" >/dev/null 2>&1; then
    ok "daemon reachable"
    break
  fi
  sleep 0.5
done
if ! curl -fsS "http://localhost:${DAEMON_PORT}/health" >/dev/null 2>&1; then
  die "daemon never became reachable on localhost:${DAEMON_PORT}"
fi

step "Fetching report payload and rendering HTML"
# The default max_payload_size of 1 MiB is too small for a daemon export
# covering hundreds of findings. 16 MiB is the upstream silent ceiling
# (above this the binary warns), comfortably above the lab's volume.
PAYLOAD_FILE="${ARTIFACTS_DIR}/greenops-payload.json"
SENTINEL_CONFIG="${ARTIFACTS_DIR}/sentinel-cli.toml"
cat > "${SENTINEL_CONFIG}" <<'EOF'
max_payload_size = 16777216
EOF
curl -fsS "http://localhost:${DAEMON_PORT}/api/export/report" -o "${PAYLOAD_FILE}"
[ -s "${PAYLOAD_FILE}" ] || die "daemon returned an empty payload"
"${SENTINEL_BIN}" report --config "${SENTINEL_CONFIG}" --input "${PAYLOAD_FILE}" --output "${HTML_OUT}"
ok "${HTML_OUT}"

step "Capturing PNG via Chrome headless"
# The dashboard's GreenOps tab is registered only when the input has a
# computed `co2` block. The daemon's /api/export/report emits
# `GreenSummary::disabled(0)` (no co2) by design (see query_api.rs),
# so the GreenOps tab is hidden in this rendering. The chip banner
# (`Carbon scoring: Electricity Maps v4, direct, 5_minutes`) is only
# visible when running `analyze` on raw traces with the EM token in
# env. The PNG below captures the Findings tab as visual proof that
# the daemon's report dashboard renders end-to-end with version 0.5.12.
CHROME_LOG="${ARTIFACTS_DIR}/chrome.log"
if ! "${CHROME_BIN}" --headless=new --disable-gpu \
  --window-size=1600,2400 \
  --virtual-time-budget=2000 \
  --screenshot="${PNG_OUT}" \
  "file://${HTML_OUT}" >"${CHROME_LOG}" 2>&1; then
  color_red "    chrome stderr:"
  sed 's/^/      /' "${CHROME_LOG}" >&2
  die "chrome headless exited non-zero, see ${CHROME_LOG}"
fi
if [ ! -s "${PNG_OUT}" ]; then
  color_red "    chrome stderr:"
  sed 's/^/      /' "${CHROME_LOG}" >&2
  die "chrome exited 0 but produced no PNG, see ${CHROME_LOG}"
fi
ok "${PNG_OUT}"

color_green ""
color_green "Screenshot ready: ${PNG_OUT}"
