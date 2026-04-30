#!/usr/bin/env bash
# Deploy GitLab CE in namespace gitlab-ce via Helm.
# Pinned to chart 9.11.2 (app v18.11.2). See helm/values/gitlab-ce.yaml.
# Usage: ./scripts/up-gitlab.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="gitlab-ce"
RELEASE_NAME="gitlab"
CHART_VERSION="9.11.2"
DAEMON_PORT="8181"
PORT_FORWARD_PID_FILE="/tmp/gitlab-port-forward.pid"
PORT_FORWARD_LOG="/tmp/gitlab-port-forward.log"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

step "Adding gitlab Helm repo"
helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
helm repo update gitlab >/dev/null

step "helm upgrade --install ${RELEASE_NAME} (chart ${CHART_VERSION}, ~10 min)"
helm upgrade --install "${RELEASE_NAME}" gitlab/gitlab \
  --version "${CHART_VERSION}" \
  -n "${NAMESPACE}" --create-namespace \
  -f helm/values/gitlab-ce.yaml \
  --timeout 15m --wait

step "Starting background port-forward on :${DAEMON_PORT}"
# Stop any prior port-forward and wait for it to release the socket
# before binding a new one. Without the wait, the new kubectl can race
# the kernel's TIME_WAIT and bail out on "address already in use".
if [ -f "${PORT_FORWARD_PID_FILE}" ]; then
  OLD_PID="$(cat "${PORT_FORWARD_PID_FILE}")"
  kill "${OLD_PID}" 2>/dev/null || true
  rm -f "${PORT_FORWARD_PID_FILE}"
  while kill -0 "${OLD_PID}" 2>/dev/null; do sleep 0.1; done
fi
kubectl -n "${NAMESPACE}" port-forward "svc/${RELEASE_NAME}-webservice-default" \
  "${DAEMON_PORT}:${DAEMON_PORT}" >"${PORT_FORWARD_LOG}" 2>&1 &
echo $! > "${PORT_FORWARD_PID_FILE}"

step "Waiting for the GitLab API to respond"
for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:${DAEMON_PORT}/-/readiness" >/dev/null 2>&1; then
    ok "GitLab API ready at http://localhost:${DAEMON_PORT}"
    color_green ""
    color_green "Login as root with the password from the Secret:"
    color_green "  kubectl -n ${NAMESPACE} get secret gitlab-initial-root-password \\"
    color_green "    -o jsonpath='{.data.password}' | base64 -d; echo"
    exit 0
  fi
  sleep 5
done
die "GitLab API never came up. Inspect: kubectl -n ${NAMESPACE} get pods, ${PORT_FORWARD_LOG}"
