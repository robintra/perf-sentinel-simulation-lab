#!/usr/bin/env bash
# Primary host access mechanism for the lab. The k3d loadbalancer port
# mappings declared in cluster/k3d-config.yaml only route to NodePort
# and LoadBalancer services. Our services are ClusterIP and servicelb
# is off, so kubectl port-forward is what actually reaches the
# workloads.
#
# bootstrap.sh runs `start` at the end of `make up`. teardown.sh runs
# `stop` at the beginning of `make down`. Manual invocation is
# supported for debugging and recovery.
#
# Usage: ./scripts/port-forward.sh start
#        ./scripts/port-forward.sh stop
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${REPO_ROOT}/tmp"
mkdir -p "${TMP_DIR}"

start_one() {
  local name="$1" namespace="$2" service="$3" local_port="$4" remote_port="$5"
  local pid_file="${TMP_DIR}/pf-${name}.pid"
  local log_file="${TMP_DIR}/pf-${name}.log"
  if [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    echo "[skip] ${name} already running (pid $(cat "${pid_file}"))"
    return
  fi
  # Auto-reconnect wrapper: re-spawns kubectl port-forward when it exits
  # (pod rollout, service mirror, daemon restart). Without this,
  # verify-all-scenarios cascades into "daemon unreachable" failures
  # from the 15th scenario on, because mutations on
  # svc/perf-sentinel-daemon kill the static forward and nothing
  # reconnects. The 2s sleep gives k8s time to repopulate endpoints.
  : > "${log_file}"
  (
    trap 'exit 0' TERM INT
    while true; do
      kubectl -n "${namespace}" port-forward "svc/${service}" \
        "${local_port}:${remote_port}" >> "${log_file}" 2>&1 || true
      printf '[pf-watcher] %s disconnected, reconnecting in 2s\n' "${name}" >> "${log_file}"
      sleep 2
    done
  ) &
  local pid=$!
  echo "${pid}" > "${pid_file}"
  echo "[start] ${name} pid=${pid} (svc/${service} ${local_port} -> ${remote_port}, auto-reconnect)"
}

stop_one() {
  local name="$1"
  local pid_file="${TMP_DIR}/pf-${name}.pid"
  if [ ! -f "${pid_file}" ]; then
    echo "[skip] ${name} not running"
    return
  fi
  local pid
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    # Kill the kubectl child first so the wrapper while-loop sees its
    # exit and is then SIGTERM'd cleanly via the trap (instead of
    # spawning one last reconnect attempt).
    pkill -P "${pid}" 2>/dev/null || true
    kill "${pid}" 2>/dev/null || true
    echo "[stop] ${name} pid=${pid}"
  fi
  rm -f "${pid_file}"
}

cmd="${1:-start}"
case "${cmd}" in
  start)
    start_one grafana    observability kube-prometheus-stack-grafana    3000  3000
    start_one daemon     observability perf-sentinel-daemon            14318 14318
    start_one tempo      observability tempo                            3200  3200
    start_one prometheus observability kube-prometheus-stack-prometheus 9090  9090
    ;;
  stop)
    stop_one grafana
    stop_one daemon
    stop_one tempo
    stop_one prometheus
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
