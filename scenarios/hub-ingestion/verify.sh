#!/usr/bin/env bash
# The daemon-to-Hub chain, over the shared lab pair.
#
# This is the root of the ecosystem scenarios: everything downstream (the
# derived status, the mutation lineage, the plugin contract) assumes findings
# actually reach the Hub and come back out in a shape the IDE plugins can read.
# Nothing asserted that before, in any repo: the Hub's own tests drive a fake
# daemon, and the daemon's tests never see a Hub.
#
# The lab wires push AND poll on one source id on purpose. Both are exercised
# permanently, and their differing `unreachable_since` semantics are proven
# apart, in scenarios/hub-source-reachability, which owns an isolated pair so it
# can partition the network without disturbing every other scenario.
#
# Sub-tests:
#   1. the Hub serves findings the daemon produced
#   2. the envelope stays plugin-compatible: the daemon's own fields survive
#      verbatim and the six Hub-owned keys are present and sane
#   3. the trace lookup round-trips a sample_trace_id
#   4. a malformed import is rejected and counted, without poisoning the batch
#   5. the daemon's own export counters agree that the push path is live

set -euo pipefail

SCENARIO="hub-ingestion"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

HUB_PORT="${HUB_LOCAL_PORT:-8080}"
DAEMON_PORT="${DAEMON_LOCAL_PORT:-14318}"
SERVICE="${HUB_INGESTION_SERVICE:-order-service}"

rm -rf "${TMP_DIR}"; mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PF_HUB_PID=""
cleanup() { [ -n "${PF_HUB_PID}" ] && kill "${PF_HUB_PID}" 2>/dev/null || true; }
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

step "0. Pre-flight"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
kubectl -n observability get deploy/perf-sentinel-hub >/dev/null 2>&1 \
  || die "no Hub in the cluster. Run: make seed-hub-local"
kubectl -n observability rollout status deploy/perf-sentinel-hub --timeout=120s >/dev/null \
  || die "the Hub is not ready"
ok "the Hub is running"

# The Hub's API is closed to the cluster except for the daemon's push, so read
# it through the kubelet proxy like every other scenario does.
#
# `scripts/port-forward.sh` already owns this port and keeps a forward alive
# across the whole run. Starting a second one on top would fail to bind while
# the probe below still passed, served by the first: the scenario would look
# healthy with its own forward dead, and cleanup would kill a process that
# never served anything. Reuse the existing forward when it answers.
if curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null 2>&1; then
  ok "reusing the port-forward already listening on ${HUB_PORT}"
else
  kubectl -n observability port-forward svc/perf-sentinel-hub "${HUB_PORT}:8080" \
    >"${TMP_DIR}/pf.log" 2>&1 &
  PF_HUB_PID=$!
  for _ in $(seq 1 40); do
    curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -sf "http://127.0.0.1:${HUB_PORT}/health/ready" >/dev/null \
    || die "the Hub's /health/ready never answered through the port-forward: $(tail -3 "${TMP_DIR}/pf.log" 2>&1)"
  ok "port-forward up, /health/ready answers"
fi

# Drive traffic so there is something to collect, unless findings already exist.
step "1. the Hub serves findings the daemon produced"
have_findings() {
  curl -sf "http://127.0.0.1:${HUB_PORT}/api/findings?limit=1000" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0
}
COUNT="$(have_findings)"
if [ "${COUNT}" = "0" ]; then
  step "    no findings yet, driving tracegen at the shared daemon"
  # tracegen rather than validate-findings.sh: it needs no shop services, so
  # this scenario stands on its own. `make seed-tracegen` builds the image, and
  # verify-all-scenarios already runs it as a prerequisite.
  docker image inspect lab-tracegen:1 >/dev/null 2>&1 \
    || die "no lab-tracegen:1 image. Run: make seed-tracegen"
  kubectl -n observability delete job hub-ingestion-seed --ignore-not-found >/dev/null 2>&1
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: hub-ingestion-seed
  namespace: observability
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {app: tracegen}
    spec:
      restartPolicy: Never
      containers:
        - name: tracegen
          image: lab-tracegen:1
          imagePullPolicy: Never
          args:
            - "--endpoint=http://perf-sentinel-daemon.observability.svc.cluster.local:14318"
            - "--protocol=http-pb"
            - "--services=1"
            - "--tps=25"
            - "--duration=15"
            - "--mix=n_plus_one:100"
EOF
  kubectl -n observability wait --for=condition=complete job/hub-ingestion-seed --timeout=120s >/dev/null 2>&1 \
    || fail "the tracegen job did not complete: $(kubectl -n observability logs job/hub-ingestion-seed --tail=5 2>&1)"
  # A finding only exists once its trace window has closed (trace_ttl_ms), and
  # the push then flushes on flush_interval_secs. The poll is the slower net.
  for _ in $(seq 1 40); do
    COUNT="$(have_findings)"
    [ "${COUNT}" != "0" ] && break
    sleep 3
  done
  kubectl -n observability delete job hub-ingestion-seed --ignore-not-found >/dev/null 2>&1
fi
if [ "${COUNT}" != "0" ] && [ "${COUNT}" -gt 0 ] 2>/dev/null; then
  ok "${COUNT} finding(s) served by the Hub"
  record "findings reach the Hub" PASS "${COUNT} findings"
else
  fail "the Hub serves no findings after seeding"
  record "findings reach the Hub" FAIL "0 findings"
fi

curl -sf "http://127.0.0.1:${HUB_PORT}/api/findings?limit=1000" -o "${TMP_DIR}/findings.json" 2>/dev/null || true

# === 2: the envelope stays readable by the IDE plugins ===
step "2. the envelope stays plugin-compatible"
if note="$(python3 - "${TMP_DIR}/findings.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
assert rows, "no findings to inspect"
row = rows[0]

# The plugin REQUIRES stored_at_ms at envelope level and reads first_seen_ms
# and seen_count when present. The Hub re-emits the daemon envelope verbatim
# except for six keys it owns, so these must survive untouched.
for field in ("stored_at_ms", "finding"):
    assert field in row, f"the daemon's {field} did not survive the Hub"

# The six keys the Hub owns.
for field in ("first_seen", "last_seen", "max_confidence", "sources", "status"):
    assert field in row, f"the Hub did not stamp {field}"
assert isinstance(row["first_seen"], int) and row["first_seen"] > 0, "first_seen is not a timestamp"
assert row["last_seen"] >= row["first_seen"], "last_seen precedes first_seen"
assert row["status"] in ("active", "likely_resolved", "not_observed"), \
    f"unexpected status {row['status']!r}"
assert isinstance(row["sources"], list) and row["sources"], "no source observation"
src = row["sources"][0]
for field in ("name", "environment", "producer_version", "age_seconds", "status"):
    assert field in src, f"the source observation lacks {field}"
assert src["status"] in ("ok", "unreachable_since"), f"unexpected source status {src['status']!r}"

# The finding body itself is what the plugin parses.
finding = row["finding"]
for field in ("type", "severity", "service", "source_endpoint", "pattern"):
    assert field in finding, f"the finding lacks {field}"
for field in ("template", "occurrences"):
    assert field in finding["pattern"], f"the pattern lacks {field}"
print(f"status={row['status']}, source={src['status']}, type={finding['type']}")
PY
)"; then
  ok "${note}"
  record "envelope contract" PASS "${note}"
else
  fail "the served envelope does not match what the plugin parses"
  record "envelope contract" FAIL "see output above"
fi

# === 3: trace lookup ===
step "3. the trace lookup round-trips"
TRACE_ID="$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))
for r in rows:
    tid = r.get("finding", {}).get("trace_id")
    if tid:
        print(tid); break
' "${TMP_DIR}/findings.json" 2>/dev/null || true)"
if [ -n "${TRACE_ID}" ] \
   && n="$(curl -sf "http://127.0.0.1:${HUB_PORT}/api/findings/${TRACE_ID}" \
             | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" \
   && [ "${n}" -gt 0 ]; then
  ok "${n} finding(s) returned for trace ${TRACE_ID}"
  record "trace lookup" PASS "${n} for ${TRACE_ID}"
else
  fail "the trace lookup returned nothing for '${TRACE_ID:-<none>}'"
  record "trace lookup" FAIL "no rows"
fi

# === 4: a malformed import is rejected, not swallowed ===
step "4. a malformed import is counted as rejected without poisoning the batch"
KEY_FILE="${LAB_ROOT}/.perf-sentinel-hub-import-key"
if [ ! -f "${KEY_FILE}" ]; then
  fail "no import key at ${KEY_FILE}; run make seed-hub-local"
  record "malformed import" FAIL "no key"
else
  API_KEY="$(cat "${KEY_FILE}")"
  # One valid finding beside one that lacks pattern.template: the valid one
  # must commit, the broken one must be counted and dropped.
  python3 - "${TMP_DIR}/findings.json" "${TMP_DIR}/import.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
good = json.loads(json.dumps(rows[0]))
for key in ("first_seen", "last_seen", "max_confidence", "sources", "status", "lineage"):
    good.pop(key, None)
good["finding"]["signature"] = "lab_probe:hub-ingestion:probe:" + "0" * 32
bad = json.loads(json.dumps(good))
bad["finding"].pop("pattern", None)          # no pattern at all: unparseable
bad["finding"]["signature"] = "lab_probe:hub-ingestion:probe:" + "1" * 32
json.dump({"producer_version": "lab", "findings": [good, bad]}, open(sys.argv[2], "w"))
PY
  RESP="$(curl -s -X POST \
            "http://127.0.0.1:${HUB_PORT}/api/import/findings?source_id=lab-daemon" \
            -H "X-API-Key: ${API_KEY}" -H "Content-Type: application/json" \
            --data-binary "@${TMP_DIR}/import.json")"
  if note="$(printf '%s' "${RESP}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
accepted, rejected = d.get("accepted"), d.get("rejected")
assert accepted == 1, "expected 1 accepted, got %r" % (accepted,)
assert rejected == 1, "expected 1 rejected, got %r" % (rejected,)
print("accepted=1, rejected=1")
' 2>/dev/null)"; then
    ok "${note}: the valid finding committed, the broken one was counted"
    record "malformed import" PASS "${note}"
  else
    fail "the import responded ${RESP}"
    record "malformed import" FAIL "${RESP}"
  fi
fi

# === 5: the daemon agrees the push path is live ===
step "5. the daemon's own export counters confirm the push path"
if metrics="$(curl -sf "http://127.0.0.1:${DAEMON_PORT}/metrics" 2>/dev/null)"; then
  DROPPED="$(printf '%s' "${metrics}" | awk '/^perf_sentinel_hub_export_dropped_total/ {print $2}')"
  PENDING="$(printf '%s' "${metrics}" | awk '/^perf_sentinel_hub_export_pending/ {print $2}')"
  if [ -n "${DROPPED}" ] && [ -n "${PENDING}" ] && [ "${DROPPED}" = "0" ]; then
    ok "hub_export_dropped_total=0, pending=${PENDING}: nothing is being lost on the way out"
    record "export counters" PASS "dropped=0 pending=${PENDING}"
  else
    fail "hub_export_dropped_total=${DROPPED:-absent} pending=${PENDING:-absent}"
    fail "a non-zero drop count means the Hub rejected a batch or the buffer overflowed"
    record "export counters" FAIL "dropped=${DROPPED:-absent}"
  fi
else
  fail "the daemon's /metrics is unreachable on ${DAEMON_PORT} (scripts/port-forward.sh start)"
  record "export counters" FAIL "metrics unreachable"
fi

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "| Sub-test | Verdict | Note |"
  echo "| --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
} > "${REPORT}"

step "Report written to ${REPORT}"
for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
