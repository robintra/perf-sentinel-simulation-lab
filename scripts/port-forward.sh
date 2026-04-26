#!/usr/bin/env bash
# Background port-forward fallback for environments where the k3d
# loadbalancer port mappings do not work (e.g. ports already bound).
# Sprint S1 normally relies on the k3d port mappings declared in
# cluster/k3d-config.yaml, so this script is a manual escape hatch.
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
  if [ -f "${pid_file}" ] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    echo "[skip] ${name} already running (pid $(cat "${pid_file}"))"
    return
  fi
  kubectl -n "${namespace}" port-forward "svc/${service}" \
    "${local_port}:${remote_port}" \
    > "${TMP_DIR}/pf-${name}.log" 2>&1 &
  local pid=$!
  echo "${pid}" > "${pid_file}"
  echo "[start] ${name} pid=${pid} (svc/${service} ${local_port} -> ${remote_port})"
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
    kill "${pid}"
    echo "[stop] ${name} pid=${pid}"
  fi
  rm -f "${pid_file}"
}

cmd="${1:-start}"
case "${cmd}" in
  start)
    start_one grafana observability kube-prometheus-stack-grafana 3000 3000
    start_one daemon  observability perf-sentinel-daemon         14318 14318
    start_one tempo   observability tempo                         3200 3200
    ;;
  stop)
    stop_one grafana
    stop_one daemon
    stop_one tempo
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
