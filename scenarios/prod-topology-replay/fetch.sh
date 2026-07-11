#!/usr/bin/env bash
# prod-topology-replay one-off: download 3 minutes of Alibaba v2022
# production call graphs (~223 MB compressed), convert a consistent
# deterministic slice to OTLP/JSON NDJSON, and stamp the manifest with
# what the local binary observes on it. Mirrors astronomy-shop's
# capture-once/replay-forever design: only the slice + manifest are
# committed, the raw artifact stays in gitignored artifacts/alibaba/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ART="${LAB_ROOT}/artifacts/alibaba"
FIXTURES="${SCRIPT_DIR}/fixtures"
TARBALL="${ART}/CallGraph_0.tar.gz"
CSV="${ART}/CallGraph_0.csv"
SLICE="${FIXTURES}/alibaba-slice.ndjson"
MANIFEST="${FIXTURES}/fixture-manifest.json"
URL="https://aliopentrace.oss-cn-beijing.aliyuncs.com/v2022MicroservicesTraces/CallGraph/CallGraph_0.tar.gz"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
TRACES="${TRACES:-300}"

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || { echo "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

mkdir -p "${ART}" "${FIXTURES}"

if [ ! -s "${CSV}" ]; then
  [ -s "${TARBALL}" ] || { echo "==> downloading CallGraph_0.tar.gz (~223 MB)"; curl -fL -o "${TARBALL}" "${URL}"; }
  echo "==> extracting"
  tar -xzf "${TARBALL}" -C "${ART}"
fi

echo "==> converting a ${TRACES}-trace consistent slice"
python3 "${SCRIPT_DIR}/convert.py" "${CSV}" "${SLICE}" --traces "${TRACES}"

echo "==> stamping the manifest from the local binary's observation"
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${SLICE}" --format json > /tmp/prod-topology-stamp.json
python3 - "${SLICE}" "${MANIFEST}" "${TRACES}" <<'EOF'
import json, sys
out = json.load(open("/tmp/prod-topology-stamp.json"))
items = out if isinstance(out, list) else out.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
classes = sorted(set(u(it).get("type", "") for it in items) - {""})
manifest = {
    "dataset": "alibaba cluster-trace-microservices-v2022 CallGraph_0 (3 min of production)",
    "converter": "convert.py (dedup + single-root consistency filter, md5 ids, synthetic http.url carrier)",
    "traces": int(sys.argv[3]),
    "traces_analyzed": out["analysis"]["traces_analyzed"],
    "findings_total": len(items),
    "expected_finding_classes": classes,
}
json.dump(manifest, open(sys.argv[2], "w"), indent=2)
print(json.dumps(manifest, indent=2))
EOF

echo "==> done: $(wc -c < "${SLICE}" | tr -d ' ') bytes committed-slice, manifest stamped"
