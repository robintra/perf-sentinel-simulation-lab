#!/usr/bin/env bash
# limit-batch-volume: large-input batch CLI validation, no cluster needed.
#
# tracegen dumps seeded multi-format corpora (native, Jaeger, Zipkin), then
# the local perf-sentinel binary runs analyze / bench / report / diff on
# them. This doubles as the generator's own acceptance test: the planted
# n_plus_one count must reconcile with the detected n_plus_one_sql findings
# (the unambiguous pattern, exact by construction), and the three formats
# must agree at equal seed.
#
# Fast mode: ~50k traces per format. LONG_RUN=1: ~250k traces per format.
set -euo pipefail

SCENARIO="limit-batch-volume"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TRACEGEN="${REPO_ROOT}/tools/tracegen/tracegen.py"
mkdir -p "${TMP_DIR}"
rm -f "${TMP_DIR}"/*.json "${TMP_DIR}"/*.html 2>/dev/null || true

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
TRACES="${TRACES:-50000}"
[ "${LONG_RUN:-0}" = "1" ] && TRACES=250000
SEED="${SEED:-1234}"
SERVICES="${SERVICES:-64}"
ANALYZE_TIME_LIMIT_S="${ANALYZE_TIME_LIMIT_S:-120}"
BENCH_RSS_LIMIT_BYTES="${BENCH_RSS_LIMIT_BYTES:-2147483648}"  # 2 GiB
HTML_SIZE_LIMIT_BYTES="${HTML_SIZE_LIMIT_BYTES:-6291456}"     # 6 MiB

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
skip() { color_yellow "    skip: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release first)"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"

# Scenario config: pin a region so carbon scoring runs on the batch path
# too. Since 0.8.7 local batch reads are capped at 1 GiB independently of
# [daemon] max_payload_size, so no cap override is needed for the shards.
cat > "${TMP_DIR}/scenario.toml" <<EOF
[green]
enabled = true
default_region = "eu-west-3"
EOF

# =============================================================================
step "Sub-test 1: generate ${TRACES} traces per format (seed=${SEED}, services=${SERVICES})"
for fmt in native jaeger zipkin; do
  out="$(python3 "${TRACEGEN}" --protocol "dump-${fmt}" --traces "${TRACES}" --shards 1 \
        --seed "${SEED}" --services "${SERVICES}" --service-prefix batch --run-nonce fixed \
        --out "${TMP_DIR}/${fmt}" 2>/dev/null | tail -1)"
  planted="$(echo "${out}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["planted"].get("n_plus_one",0))')"
  eval "PLANTED_${fmt}=\${planted}"
  size="$(du -h "${TMP_DIR}/${fmt}"/shard-00.*.json | cut -f1)"
  ok "${fmt}: $(echo "${out}" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("%d traces, %d spans" % (d["traces"], d["spans"]))'), file ${size}, planted n+1=${planted}"
done
# Same seed must plant the same counts in every format.
[ "${PLANTED_native}" = "${PLANTED_jaeger}" ] || die "seeded generation diverged between formats"

# =============================================================================
step "Sub-test 2: analyze each format (exit 0, < ${ANALYZE_TIME_LIMIT_S}s, planted findings reconcile)"
for fmt in native jaeger zipkin; do
  f="${TMP_DIR}/${fmt}/shard-00.${fmt}.json"
  start="$(date +%s)"
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${f}" --format json --config "${TMP_DIR}/scenario.toml" \
    > "${TMP_DIR}/analyze-${fmt}.json" 2>"${TMP_DIR}/analyze-${fmt}.err" \
    || die "analyze failed on ${fmt}: $(tail -2 "${TMP_DIR}/analyze-${fmt}.err")"
  wall=$(( $(date +%s) - start ))
  eval "WALL_${fmt}=\${wall}"
  [ "${wall}" -le "${ANALYZE_TIME_LIMIT_S}" ] || die "analyze ${fmt} took ${wall}s (> ${ANALYZE_TIME_LIMIT_S}s)"
  detected="$(python3 -c "
import json
r=json.load(open('${TMP_DIR}/analyze-${fmt}.json'))
n=sum(1 for f in r['findings'] if f.get('type')=='n_plus_one_sql')
print('%d %d' % (r['analysis']['traces_analyzed'], n))
")"
  eval "DETECTED_${fmt}=\${detected}"
  ok "${fmt}: ${wall}s, traces+n_plus_one_sql = ${detected}"
done
NATIVE_N1="$(echo "${DETECTED_native}" | awk '{print $2}')"
PLANTED="${PLANTED_native}"
LOW=$(( PLANTED * 80 / 100 )); HIGH=$(( PLANTED * 120 / 100 ))
[ "${NATIVE_N1}" -ge "${LOW}" ] && [ "${NATIVE_N1}" -le "${HIGH}" ] \
  || die "native n_plus_one_sql=${NATIVE_N1} outside ±20% of planted ${PLANTED}"
# Cross-format coherence at equal seed: each format detects within ±10% of native.
for fmt in jaeger zipkin; do
  N1="$(eval "echo \"\${DETECTED_${fmt}}\"" | awk '{print $2}')"
  FLOW=$(( NATIVE_N1 * 90 / 100 )); FHIGH=$(( NATIVE_N1 * 110 / 100 ))
  [ "${N1}" -ge "${FLOW}" ] && [ "${N1}" -le "${FHIGH}" ] \
    || die "${fmt} n_plus_one_sql=${N1} incoherent with native ${NATIVE_N1}"
done
ok "planted reconciliation: native=${NATIVE_N1} vs planted=${PLANTED}, formats coherent"

# =============================================================================
step "Sub-test 3: bench on the native shard (3 iterations, RSS < 2 GiB)"
"${PERF_SENTINEL_LOCAL_BIN}" bench --input "${TMP_DIR}/native/shard-00.native.json" --iterations 3 \
  > "${TMP_DIR}/bench.json" 2>/dev/null || die "bench failed"
THROUGHPUT="$(python3 -c "import json;print(int(json.load(open('${TMP_DIR}/bench.json'))['throughput_events_per_sec']))")"
RSS_PEAK="$(python3 -c "import json;print(json.load(open('${TMP_DIR}/bench.json'))['rss_peak_bytes'] or 0)")"
[ "${RSS_PEAK}" -le "${BENCH_RSS_LIMIT_BYTES}" ] || die "bench rss_peak=${RSS_PEAK} bytes (> 2 GiB)"
ok "bench: ${THROUGHPUT} events/s, rss_peak=$(( RSS_PEAK / 1048576 )) MiB"

# =============================================================================
step "Sub-test 4: HTML report stays under the size target"
"${PERF_SENTINEL_LOCAL_BIN}" report --input "${TMP_DIR}/native/shard-00.native.json" \
  --output "${TMP_DIR}/report.html" --config "${TMP_DIR}/scenario.toml" >/dev/null 2>&1 \
  || die "report failed on the native shard"
HTML_SIZE="$(wc -c < "${TMP_DIR}/report.html" | tr -d ' ')"
[ "${HTML_SIZE}" -le "${HTML_SIZE_LIMIT_BYTES}" ] || die "report.html is ${HTML_SIZE} bytes (> 6 MiB target)"
grep -qi "findings" "${TMP_DIR}/report.html" || die "report.html lacks the findings marker"
ok "report.html: $(( HTML_SIZE / 1024 )) KiB"

# =============================================================================
step "Sub-test 5: diff across two seeded shards (exit 0 or 1, parseable JSON)"
python3 "${TRACEGEN}" --protocol dump-native --traces 5000 --shards 1 --seed 99 \
  --services "${SERVICES}" --service-prefix batch --run-nonce fixed \
  --out "${TMP_DIR}/before" >/dev/null 2>&1
DIFF_RC=0
"${PERF_SENTINEL_LOCAL_BIN}" diff --before "${TMP_DIR}/before/shard-00.native.json" \
  --after "${TMP_DIR}/native/shard-00.native.json" --format json --config "${TMP_DIR}/scenario.toml" \
  > "${TMP_DIR}/diff.json" 2>/dev/null || DIFF_RC=$?
[ "${DIFF_RC}" -le 1 ] || die "diff exited ${DIFF_RC} (expected 0 or 1)"
python3 -c "import json;json.load(open('${TMP_DIR}/diff.json'))" || die "diff output is not JSON"
ok "diff exit=${DIFF_RC}, JSON parses"

# =============================================================================
step "Sub-test 6: an input past the 1 GiB batch cap is rejected loudly"
# Sparse file: trips the metadata pre-check instantly, no real data written.
python3 -c "
f=open('${TMP_DIR}/oversized.json','w'); f.truncate(1024*1024*1024+1); f.close()"
NEG_RC=0
"${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${TMP_DIR}/oversized.json" --format json \
  > /dev/null 2>"${TMP_DIR}/neg.err" || NEG_RC=$?
[ "${NEG_RC}" -ne 0 ] || die "an input past the 1 GiB batch cap was accepted"
grep -qiE "exceeds maximum" "${TMP_DIR}/neg.err" || die "rejection does not name the limit: $(tail -1 "${TMP_DIR}/neg.err")"
rm -f "${TMP_DIR}/oversized.json"
ok "oversized input rejected loudly (exit ${NEG_RC}): $(grep -o 'exceeds maximum of [0-9]* bytes' "${TMP_DIR}/neg.err" | head -1)"

# =============================================================================
verdict="PASS"
{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo "- Corpus: ${TRACES} traces x 3 formats, seed ${SEED}, ${SERVICES} services"
  echo ""
  echo "| check | result |"
  echo "|---|---|"
  echo "| planted n+1 vs detected (native) | ${PLANTED} vs ${NATIVE_N1} |"
  for fmt in native jaeger zipkin; do
    echo "| analyze ${fmt} wall time | $(eval "echo \"\${WALL_${fmt}}\"")s |"
  done
  echo "| bench throughput | ${THROUGHPUT} events/s |"
  echo "| bench rss peak | $(( RSS_PEAK / 1048576 )) MiB |"
  echo "| report.html size | $(( HTML_SIZE / 1024 )) KiB |"
  echo "| diff exit | ${DIFF_RC} |"
  echo ""
  echo "Verdict: **${verdict}**"
} > "${REPORT}"
color_green "PASS — report at ${REPORT}"
