#!/usr/bin/env bash
# Capture traces from the local Tempo instance and convert them to
# Jaeger JSON format, which is one of the formats consumable by
# `perf-sentinel analyze --input`. The output is the static fixture
# used by the GitLab CI template test project.
#
# Pipeline:
#   1. Query Tempo /api/search for traces of each lab service.
#   2. Fetch each trace via /api/traces/<id> (OTLP-JSON).
#   3. Convert OTLP-JSON to Jaeger {"data": [...]} format.
#   4. Validate the fixture parses with `analyze --input`.
#
# The Tempo port-forward (3200) must be active. Run `make up` if not.
# Usage: ./scripts/capture-trace-fixture.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

TEMPO_URL="http://localhost:3200"
SERVICES=(order-service payment-service notification-service)
LIMIT_PER_SERVICE=50
LOOKBACK_SECONDS=3600
OUTPUT_FILE="${REPO_ROOT}/artifacts/fixtures/em-real-time-traces.json"
PERF_SENTINEL_BIN="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}/target/release/perf-sentinel"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

step "Checking Tempo reachability"
curl -fsS "${TEMPO_URL}/ready" >/dev/null \
  || die "Tempo not reachable at ${TEMPO_URL}. Run make up."
ok "Tempo ready"

mkdir -p "$(dirname "${OUTPUT_FILE}")"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

step "Searching Tempo for traces of ${SERVICES[*]}"
ALL_IDS_FILE="${WORK_DIR}/trace-ids.txt"
: > "${ALL_IDS_FILE}"
NOW_SEC=$(date +%s)
START_SEC=$((NOW_SEC - LOOKBACK_SECONDS))
for svc in "${SERVICES[@]}"; do
  curl -fsS --get "${TEMPO_URL}/api/search" \
    --data-urlencode "tags=service.name=${svc}" \
    --data-urlencode "limit=${LIMIT_PER_SERVICE}" \
    --data-urlencode "start=${START_SEC}" \
    --data-urlencode "end=${NOW_SEC}" \
    | jq -r '.traces[]?.traceID' \
    >> "${ALL_IDS_FILE}"
done
sort -u "${ALL_IDS_FILE}" -o "${ALL_IDS_FILE}"
COUNT=$(wc -l < "${ALL_IDS_FILE}")
[ "${COUNT}" -gt 0 ] || die "no traces found in last ${LOOKBACK_SECONDS}s. Run make validate-findings to generate traffic."
ok "${COUNT} unique trace IDs collected"

step "Fetching trace bodies and converting to Jaeger format"
BATCHES_FILE="${WORK_DIR}/batches.ndjson"
: > "${BATCHES_FILE}"
while read -r trace_id; do
  curl -fsS "${TEMPO_URL}/api/traces/${trace_id}" >> "${BATCHES_FILE}"
  printf '\n' >> "${BATCHES_FILE}"
done < "${ALL_IDS_FILE}"

python3 - "${BATCHES_FILE}" "${OUTPUT_FILE}" <<'PY'
"""Convert Tempo OTLP-JSON traces (one per line) to a single Jaeger JSON file.

Each input line is a Tempo /api/traces/<id> response of the form:
    {"batches": [{"resource": {...}, "scopeSpans": [{"spans": [...]}, ...]}, ...]}

Output is the Jaeger JSON export shape consumed by perf-sentinel analyze:
    {"data": [{"traceID": "...", "spans": [...], "processes": {...}}]}
"""
import json
import sys
from collections import defaultdict


def attr_to_str(value):
    """Flatten an OTLP attribute value object to a Jaeger tag value."""
    if "stringValue" in value:
        return value["stringValue"]
    if "intValue" in value:
        return value["intValue"]
    if "boolValue" in value:
        return value["boolValue"]
    if "doubleValue" in value:
        return value["doubleValue"]
    if "arrayValue" in value:
        return [attr_to_str(v) for v in value["arrayValue"].get("values", [])]
    return None


def attrs_to_dict(attrs):
    return {a["key"]: attr_to_str(a["value"]) for a in attrs or []}


def hex_or_none(value):
    return value if value else None


def convert(input_path, output_path):
    traces = defaultdict(lambda: {"spans": [], "processes": {}})
    process_counter = defaultdict(int)

    with open(input_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            doc = json.loads(line)
            for batch in doc.get("batches", []):
                resource_attrs = attrs_to_dict(batch.get("resource", {}).get("attributes"))
                service_name = resource_attrs.get("service.name", "unknown-service")
                for scope_spans in batch.get("scopeSpans", []):
                    for span in scope_spans.get("spans", []):
                        trace_id = span["traceId"]
                        bucket = traces[trace_id]
                        process_id = next(
                            (pid for pid, p in bucket["processes"].items() if p == service_name),
                            None,
                        )
                        if process_id is None:
                            process_counter[trace_id] += 1
                            process_id = f"p{process_counter[trace_id]}"
                            bucket["processes"][process_id] = service_name
                        start_nano = int(span["startTimeUnixNano"])
                        end_nano = int(span["endTimeUnixNano"])
                        start_micros = start_nano // 1000
                        duration_micros = max((end_nano - start_nano) // 1000, 0)
                        references = []
                        parent = hex_or_none(span.get("parentSpanId"))
                        if parent:
                            references.append({
                                "refType": "CHILD_OF",
                                "traceID": trace_id,
                                "spanID": parent,
                            })
                        attrs = attrs_to_dict(span.get("attributes"))
                        merged = {**resource_attrs, **attrs}
                        tags = [
                            {"key": k, "value": v}
                            for k, v in merged.items()
                            if v is not None and not isinstance(v, list)
                        ]
                        bucket["spans"].append({
                            "spanID": span["spanId"],
                            "operationName": span.get("name", ""),
                            "references": references,
                            "startTime": start_micros,
                            "duration": duration_micros,
                            "processID": process_id,
                            "tags": tags,
                        })

    out = {
        "data": [
            {
                "traceID": trace_id,
                "spans": data["spans"],
                "processes": {
                    pid: {"serviceName": svc} for pid, svc in data["processes"].items()
                },
            }
            for trace_id, data in traces.items()
        ]
    }
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    print(f"converted {len(out['data'])} traces, "
          f"{sum(len(t['spans']) for t in out['data'])} spans total")


convert(sys.argv[1], sys.argv[2])
PY
ok "fixture written: ${OUTPUT_FILE}"

step "Validating fixture with perf-sentinel analyze --input"
[ -x "${PERF_SENTINEL_BIN}" ] || die "perf-sentinel binary not found at ${PERF_SENTINEL_BIN}"
# Pin the supported family so an old binary can't silently produce a
# fixture in a format the lab daemon no longer accepts. Bump alongside
# the daemon image in manifests/perf-sentinel-daemon.yaml.
PSV="$("${PERF_SENTINEL_BIN}" --version | awk '{print $2}')"
case "${PSV}" in
  0.5.*) ;;
  *) die "perf-sentinel ${PSV} not supported, expected 0.5.x to match the lab daemon" ;;
esac
ANALYZE_OUT="${WORK_DIR}/analyze.json"
ANALYZE_ERR="${WORK_DIR}/analyze.err"
if ! "${PERF_SENTINEL_BIN}" analyze --input "${OUTPUT_FILE}" --format json \
       >"${ANALYZE_OUT}" 2>"${ANALYZE_ERR}"; then
  color_red "    analyze stderr:"
  sed 's/^/      /' "${ANALYZE_ERR}" >&2
  die "analyze --input failed"
fi
FINDINGS_COUNT=$(jq '.findings | length' "${ANALYZE_OUT}")
ok "fixture parses, analyze produced ${FINDINGS_COUNT} findings"

color_green ""
color_green "Fixture ready: $(du -h "${OUTPUT_FILE}" | awk '{print $1}'), ${COUNT} traces"
color_green "Next: validate calibration with --ci against artifacts/fixtures/perf-sentinel-test.toml"
