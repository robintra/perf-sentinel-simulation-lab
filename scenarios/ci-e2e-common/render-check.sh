#!/usr/bin/env bash
# Shared by the ci-e2e-* scenarios: load a perf-sentinel HTML report in headless
# Chrome and report whether the dashboard ACTUALLY RENDERED.
#
# Why this exists: the report packs its CSS and its ~4500 lines of JavaScript
# inline, and the static DOM carries no tab, no table row and no value — every
# one of them is built at load time from the embedded JSON. The report declares
# its own permissive CSP in a <meta>, but a <meta> CSP and an HTTP header CSP
# INTERSECT, strictest wins. A CI system that serves artifacts under a strict
# header therefore shows a page with a logo, some empty column headers and
# nothing else, and nothing appears in the build log.
#
# Two modes:
#   render-check.sh <report.html> <csp|none>          serve locally, stamp <csp>
#   render-check.sh <http://...> none <report.html>   fetch through a REAL server
#
# The URL mode is the one that matters for a CI end-to-end: only the CI system's
# own HTTP response carries its own CSP. The third argument is the local copy of
# the same report, used as the pre-JavaScript baseline.
#
# Prints one line of evidence on stdout:
#   RENDERED rows=<n>/<static> tabs=<n>/<static>
#   BLANK    rows=<n>/<static> tabs=<n>/<static>
# and exits 0 either way — which of the two is expected belongs to the caller,
# since both are legitimate depending on the CSP under test.
# Exit 2 means the check itself could not run (no Chrome, no python3, ...).
set -uo pipefail

TARGET="${1:?usage: render-check.sh <report.html|url> <csp|none> [baseline.html]}"
CSP="${2:?usage: render-check.sh <report.html|url> <csp|none> [baseline.html]}"
BASELINE="${3:-}"
PORT="${RENDER_CHECK_PORT:-18899}"
BUDGET_MS="${RENDER_CHECK_BUDGET_MS:-4000}"

command -v python3 >/dev/null 2>&1 || { echo "render-check: python3 missing" >&2; exit 2; }

# Same resolution order as scripts/capture-greenops-screenshot.sh.
resolve_chrome() {
  local c
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    [ -x "${c}" ] && { printf '%s' "${c}"; return 0; }
  done
  for c in google-chrome chromium chromium-browser; do
    command -v "${c}" >/dev/null 2>&1 && { command -v "${c}"; return 0; }
  done
  return 1
}
CHROME="$(resolve_chrome)" || { echo "render-check: no Chrome or Chromium" >&2; exit 2; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

case "${TARGET}" in
  http://*|https://*)
    URL="${TARGET}"
    [ -s "${BASELINE}" ] || { echo "render-check: URL mode needs a local baseline copy" >&2; exit 2; }
    ;;
  *)
    [ -s "${TARGET}" ] || { echo "render-check: no report at ${TARGET}" >&2; exit 2; }
    BASELINE="${TARGET}"
    cp "${TARGET}" "${WORK}/index.html"
    # A static file server that stamps the CSP header a CI system would stamp.
    # Serving over HTTP rather than file:// is the point: a header-borne CSP
    # only exists on an HTTP response.
    cat > "${WORK}/serve.py" <<'PY'
import http.server, os, sys, functools

csp = os.environ.get("RENDER_CHECK_CSP", "")

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        if csp:
            self.send_header("Content-Security-Policy", csp)
        super().end_headers()
    def log_message(self, *args):
        pass

http.server.HTTPServer(
    ("127.0.0.1", int(sys.argv[1])),
    functools.partial(Handler, directory=sys.argv[2]),
).serve_forever()
PY
    RENDER_CHECK_CSP="$([ "${CSP}" = "none" ] && echo "" || echo "${CSP}")" \
      python3 "${WORK}/serve.py" "${PORT}" "${WORK}" &
    SERVER_PID=$!
    URL="http://127.0.0.1:${PORT}/index.html"
    ;;
esac

for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "${URL}" 2>/dev/null && break
  sleep 0.25
done
curl -fsS -o /dev/null "${URL}" 2>/dev/null \
  || { echo "render-check: ${URL} never answered" >&2; exit 2; }

# --dump-dom prints the DOM AFTER scripts have run, which is exactly the
# difference being observed. --virtual-time-budget lets the load settle without
# a fixed sleep.
"${CHROME}" --headless=new --disable-gpu --no-sandbox \
  --virtual-time-budget="${BUDGET_MS}" \
  --dump-dom "${URL}" > "${WORK}/dom.html" 2>/dev/null

# Both metrics are DIFFERENTIAL: rendered DOM versus the file on disk. A plain
# count would be contaminated, because --dump-dom also prints the inline script
# source, and that source contains the very markup strings being looked for.
# What cannot be faked is the count going UP once the script has executed.
count_markers() {  # $1 = html file
  python3 - "$1" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
print(len(re.findall(r"<tr[\s>]", html)), len(re.findall(r'role="tab"', html)))
PY
}

read -r ROWS TABS <<< "$(count_markers "${WORK}/dom.html")"
read -r STATIC_ROWS STATIC_TABS <<< "$(count_markers "${BASELINE}")"

if [ "${ROWS}" -gt "${STATIC_ROWS}" ] && [ "${TABS}" -gt "${STATIC_TABS}" ]; then
  echo "RENDERED rows=${ROWS}/${STATIC_ROWS} tabs=${TABS}/${STATIC_TABS}"
else
  echo "BLANK rows=${ROWS}/${STATIC_ROWS} tabs=${TABS}/${STATIC_TABS}"
fi
