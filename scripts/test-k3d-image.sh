#!/usr/bin/env bash
# Self-test for scripts/k3d-image.sh. No cluster and no docker needed: `k3d`,
# `docker` and `sleep` are shell-function stubs, which bash resolves before
# PATH. Guards the probe retry, whose absence failed validate-multistack while
# k3d itself logged "Successfully imported" on every node.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/k3d-image.sh
source "${REPO_ROOT}/scripts/k3d-image.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

IMAGE="quarkus-svc:s2"
NODES="k3d-lab-server-0 server lab
k3d-lab-agent-0 agent lab
k3d-lab-agent-1 agent lab"
FLAKY_NODE=""
FLAKY_TIMES=0
ABSENT_NODE=""

k3d()   { [ "${1}" = "node" ] && printf '%s\n' "${NODES}"; }
sleep() { :; }
# docker exec <node> ctr -n k8s.io images list -q
docker() {
  local node="$2" n
  if [ "${node}" = "${FLAKY_NODE}" ]; then
    n="$(cat "${TMP}/count" 2>/dev/null || echo 0)"
    echo "$((n + 1))" > "${TMP}/count"
    if [ "$((n + 1))" -le "${FLAKY_TIMES}" ]; then return 1; fi
  fi
  if [ "${node}" = "${ABSENT_NODE}" ]; then echo "docker.io/library/other:tag"; return 0; fi
  echo "docker.io/library/${IMAGE}"
}

fail() { echo "FAIL: $*"; exit 1; }

echo "==> every node carries the image"
diag="$(verify_k3d_image_on_all_nodes lab "${IMAGE}")" || fail "expected pass, got: ${diag}"
echo "    ok"

echo "==> a node whose probe fails twice is not reported missing"
FLAKY_NODE="k3d-lab-agent-0"; FLAKY_TIMES=2
diag="$(verify_k3d_image_on_all_nodes lab "${IMAGE}")" || fail "flaky probe reported missing: ${diag}"
[ "$(cat "${TMP}/count")" = "3" ] || fail "expected 3 probes on the flaky node, got $(cat "${TMP}/count")"
FLAKY_NODE=""; FLAKY_TIMES=0
echo "    ok"

echo "==> a node genuinely without the image is reported"
ABSENT_NODE="k3d-lab-agent-0"
diag="$(verify_k3d_image_on_all_nodes lab "${IMAGE}")" && fail "expected failure, got pass"
[ "${diag}" = "k3d-lab-agent-0" ] || fail "expected the missing node name, got: ${diag}"
ABSENT_NODE=""
echo "    ok"

echo "==> no enumerable node is an environment error, not a missing image"
NODES=""
diag="$(verify_k3d_image_on_all_nodes lab "${IMAGE}")" && fail "expected failure, got pass"
case "${diag}" in *"no k3d worker node enumerable"*) ;; *) fail "unexpected diagnostic: ${diag}";; esac
echo "    ok"

echo "PASS: k3d image verification retries a flaky probe and still fails on a real miss"
