#!/usr/bin/env bash
# Optional live leg of the datadog-bridge scenario: dd-trace v0.4 -> real OTel
# Collector datadogreceiver -> perf-sentinel daemon -> assert a SQL finding.
# Self-contained (own daemon + collector). Exit 0 on success, non-0 on any
# infra failure (verify.sh treats non-0 as SKIP, never a scenario failure).
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${PERF_SENTINEL_LOCAL_BIN:-${HOME}/RustroverProjects/perf-sentinel/target/release/perf-sentinel}"
# Pinned: keep in sync with verify.sh COLLECTOR_IMAGE (the datadogreceiver is alpha).
IMG="${COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.155.0}"
PORT="${DAEMON_HTTP_PORT:-14396}"; GRPC="${DAEMON_GRPC_PORT:-14397}"
URL="http://127.0.0.1:${PORT}"
TMP="$(mktemp -d)"
DPID=""

# Free our loopback ports: the port lives in the TOML, not the argv, so a
# port-pattern pkill never matches. Kill by the unique config path and by
# whoever holds the ports (a SIGKILLed prior run).
free_ports() {
  pkill -f "perf-sentinel watch.*${TMP}/d.toml" 2>/dev/null || true
  for p in "${PORT}" "${GRPC}"; do
    lsof -ti "tcp:${p}" 2>/dev/null | while read -r pid; do kill "${pid}" 2>/dev/null || true; done
  done
}
cleanup() {
  docker rm -f ddbridge-collector >/dev/null 2>&1 || true
  [ -n "${DPID}" ] && kill "${DPID}" 2>/dev/null || true
}
trap cleanup EXIT

free_ports
sleep 1
# Daemon config kept in lockstep with verify.sh start_local_daemon.
cat > "${TMP}/d.toml" <<EOF
[daemon]
listen_address = "0.0.0.0"
listen_port_http = ${PORT}
listen_port_grpc = ${GRPC}
api_enabled = true
trace_ttl_ms = 2000
environment = "staging"

[daemon.ack]
enabled = false

[detection]
n_plus_one_min_occurrences = 5
EOF
"${BIN}" watch --config "${TMP}/d.toml" > "${TMP}/d.log" 2>&1 &
DPID=$!
for _ in $(seq 1 40); do curl -fsS "${URL}/api/status" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "${URL}/api/status" >/dev/null 2>&1 || { echo "daemon not ready"; exit 1; }

# Render the collector config with the actual daemon port (the committed
# collector.yaml carries the 14396 default; substitute whatever PORT is in use).
sed "s#host.docker.internal:14396#host.docker.internal:${PORT}#" \
  "${DIR}/collector.yaml" > "${TMP}/collector.yaml"

docker rm -f ddbridge-collector >/dev/null 2>&1 || true
docker run -d --name ddbridge-collector --add-host=host.docker.internal:host-gateway \
  -p 8126:8126 -v "${TMP}/collector.yaml:/cfg/config.yaml:ro" \
  "${IMG}" --config=/cfg/config.yaml >/dev/null 2>&1 || { echo "collector start failed"; exit 1; }
# Gate on the collector's real "all components started" banner (emitted at info
# level, which collector.yaml now sets). It short-circuits as soon as the
# receiver is up: not a fixed wait, and the in-loop crash check fails fast.
# A bare TCP probe of the host-mapped :8126 is unreliable on Docker Desktop:
# the port proxy accepts before the receiver inside the container binds.
ready=0
for _ in $(seq 1 30); do
  docker logs ddbridge-collector 2>&1 | grep -qi "Everything is ready" && { ready=1; break; }
  docker ps --format '{{.Names}}' | grep -q ddbridge-collector \
    || { echo "collector crashed: $(docker logs ddbridge-collector 2>&1 | tail -3)"; exit 1; }
  sleep 1
done
[ "${ready}" = "1" ] || { echo "datadogreceiver not ready (no startup banner)"; exit 1; }
sleep 1   # let the host port-proxy settle after the receiver binds

python3 "${DIR}/dd_send.py" || { echo "dd_send failed"; exit 1; }
sleep 6
TYPES="$(curl -fsS "${URL}/api/findings" | python3 -c '
import sys, json
items = json.load(sys.stdin)
items = items if isinstance(items, list) else items.get("findings", [])
def u(it): return it.get("finding", it) if isinstance(it, dict) else {}
print(" ".join(u(it).get("type","") for it in items if u(it).get("service") == "dd-shop"))
')"
echo "live dd-shop finding types: [${TYPES}]"
echo "${TYPES}" | grep -Eq 'n_plus_one_sql|redundant_sql' || { echo "no SQL finding via live bridge"; exit 1; }
echo "live leg OK"
