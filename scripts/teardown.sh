#!/usr/bin/env bash
# Teardown the perf-sentinel simulation lab.
# Usage: ./scripts/teardown.sh [--clean-images]
set -euo pipefail

CLUSTER_NAME="perf-sentinel-lab"
PERF_SENTINEL_VERSION="0.5.4"
CLEAN_IMAGES="false"

for arg in "$@"; do
  case "${arg}" in
    --clean-images) CLEAN_IMAGES="true" ;;
    *) echo "unknown argument: ${arg}"; exit 1 ;;
  esac
done

color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_red  "    warn: $*"; }

stop_port_forwards() {
  step "Stopping host port-forwards"
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  "${REPO_ROOT}/scripts/port-forward.sh" stop 2>/dev/null || true
  ok "port-forwards stopped"
}

teardown_cluster() {
  step "Deleting k3d cluster ${CLUSTER_NAME}"
  if ! k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
    warn "cluster not found, nothing to do"
    return
  fi
  k3d cluster delete "${CLUSTER_NAME}"
  ok "cluster deleted"
}

clean_images() {
  if [ "${CLEAN_IMAGES}" != "true" ]; then
    return
  fi
  step "Removing perf-sentinel images from local docker"
  docker rmi "perf-sentinel:${PERF_SENTINEL_VERSION}" 2>/dev/null || true
  docker rmi "ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}" 2>/dev/null || true
  ok "images removed"
}

main() {
  stop_port_forwards
  teardown_cluster
  clean_images
  step "Teardown complete"
}

main "$@"
