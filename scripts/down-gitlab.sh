#!/usr/bin/env bash
# Tear down the GitLab CE release and namespace. Removes the local
# port-forward state but leaves /tmp/gitlab-pat.txt intact unless the
# uninstall succeeds.
# Usage: ./scripts/down-gitlab.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="gitlab-ce"
RELEASE_NAME="gitlab"
PORT_FORWARD_PID_FILE="/tmp/gitlab-port-forward.pid"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }

step "Stopping the background port-forward"
if [ -f "${PORT_FORWARD_PID_FILE}" ]; then
  kill "$(cat "${PORT_FORWARD_PID_FILE}")" 2>/dev/null || true
  rm -f "${PORT_FORWARD_PID_FILE}"
  ok "port-forward stopped"
fi

step "helm uninstall ${RELEASE_NAME}"
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait || true

step "Deleting namespace ${NAMESPACE}"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

step "Cleaning local state"
rm -f /tmp/gitlab-pat.txt /tmp/gitlab-project.json /tmp/gitlab-port-forward.log
ok "GitLab CE removed"
