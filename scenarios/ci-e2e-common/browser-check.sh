#!/usr/bin/env bash
# Execute a perf-sentinel report in real Chrome and print rendered text or CSV.

set -euo pipefail

REPORT="${1:?usage: browser-check.sh <report.html> <dom|findings|correlations>}"
MODE="${2:?usage: browser-check.sh <report.html> <dom|findings|correlations>}"
PORT="${BROWSER_CHECK_PORT:-18909}"
BUDGET_MS="${BROWSER_CHECK_BUDGET_MS:-5000}"

case "${MODE}" in dom|findings|correlations) ;; *) echo "unknown mode: ${MODE}" >&2; exit 2 ;; esac
[ -s "${REPORT}" ] || { echo "report not found: ${REPORT}" >&2; exit 2; }

resolve_chrome() {
  local candidate
  for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                   "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
  done
  for candidate in google-chrome chromium chromium-browser; do
    command -v "${candidate}" >/dev/null 2>&1 && { command -v "${candidate}"; return 0; }
  done
  return 1
}

CHROME="$(resolve_chrome)" || { echo "Chrome or Chromium not found" >&2; exit 2; }
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

python3 - "${REPORT}" "${WORK}/index.html" "${MODE}" <<'PY'
import pathlib, sys
source, path, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
prelude = '''<script>
window.__capturedCsv = "";
URL.createObjectURL = function (blob) {
  blob.text().then(function (text) { window.__capturedCsv = text; });
  return "blob:perf-sentinel-browser-check";
};
HTMLAnchorElement.prototype.click = function () {};
</script>
'''
probe = f'''<script>
var mode = {mode!r};
setTimeout(function () {{
  function finish(output) {{
    document.body.innerHTML = '<pre id="result"></pre>';
    document.getElementById("result").textContent = output;
    document.body.dataset.ready = "yes";
  }}
  if (mode === "dom") {{
    var findingsTab = document.getElementById("tab-findings");
    if (findingsTab) findingsTab.click();
    setTimeout(function () {{ finish(document.body.innerText); }}, 100);
  }} else {{
    document.getElementById(mode + "-export").click();
    setTimeout(function () {{ finish(window.__capturedCsv); }}, 250);
  }}
}}, 750);
</script>'''
html = source.read_text(encoding="utf-8")
if "</body>" not in html:
    raise SystemExit("report has no closing body tag")
marker = '<script>\n(function () {'
if marker not in html:
    raise SystemExit("report main script marker not found")
html = html.replace(marker, prelude + marker, 1)
path.write_text(html.replace("</body>", probe + "</body>", 1), encoding="utf-8")
PY

python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${WORK}" \
  >"${WORK}/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:${PORT}/index.html" >/dev/null 2>&1 && break
  sleep 0.1
done

"${CHROME}" --headless=new --disable-gpu --no-sandbox \
  --virtual-time-budget="${BUDGET_MS}" \
  --dump-dom "http://127.0.0.1:${PORT}/index.html" \
  >"${WORK}/dom.html" 2>"${WORK}/chrome.log"

python3 - "${WORK}/dom.html" <<'PY'
from html.parser import HTMLParser
import sys

class ResultParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.inside = False
        self.parts = []
    def handle_starttag(self, tag, attrs):
        if tag == "pre" and dict(attrs).get("id") == "result":
            self.inside = True
    def handle_endtag(self, tag):
        if tag == "pre" and self.inside:
            self.inside = False
    def handle_data(self, data):
        if self.inside:
            self.parts.append(data)

p = ResultParser()
p.feed(open(sys.argv[1], encoding="utf-8", errors="replace").read())
result = "".join(p.parts)
if not result:
    raise SystemExit("report browser check produced no result")
print(result, end="" if result.endswith("\n") else "\n")
PY
