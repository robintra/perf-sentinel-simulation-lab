#!/usr/bin/env bash
# Helpers to wait for Kubernetes workloads to become Ready.
# Source this file from other scripts: . scripts/wait-for-ready.sh
set -euo pipefail

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-300s}"
  echo "[wait] deployment ${namespace}/${name} (timeout ${timeout})"
  kubectl wait deployment "${name}" \
    -n "${namespace}" \
    --for=condition=Available \
    --timeout="${timeout}"
}

wait_for_statefulset() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-300s}"
  echo "[wait] statefulset ${namespace}/${name} (timeout ${timeout})"
  kubectl rollout status statefulset "${name}" \
    -n "${namespace}" \
    --timeout="${timeout}"
}

wait_for_pods_in_namespace() {
  local namespace="$1"
  local timeout="${2:-300s}"
  echo "[wait] all pods Ready in ${namespace} (timeout ${timeout})"
  kubectl wait --for=condition=Ready pods \
    --all \
    -n "${namespace}" \
    --timeout="${timeout}"
}
