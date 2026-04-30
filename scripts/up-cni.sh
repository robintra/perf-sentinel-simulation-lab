#!/usr/bin/env bash
# Bootstrap the lab with a real CNI (Cilium by default, Calico fallback
# via `./scripts/install-cni.sh calico`). The k3d cluster from
# cluster/k3d-config.yaml has Flannel disabled, so the CNI must be
# installed before any workload becomes Ready.
#
# Sequence:
#   1. k3d cluster create (cluster comes up but nodes are NotReady
#      because no CNI is installed yet).
#   2. install-cni.sh installs Cilium and waits for it to be Ready.
#      Once Cilium is up, the nodes flip to Ready.
#   3. bootstrap.sh sees the cluster already exists, skips the create
#      step, and runs the rest (Helm repos, namespaces, Postgres,
#      observability, daemon, port-forwards).
#   4. apply-network-policies enforces the zero-trust segmentation.
#
# Usage: ./scripts/up-cni.sh [cilium|calico]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CNI="${1:-cilium}"
CLUSTER_NAME="perf-sentinel-lab"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

step "Checking prerequisites"
for cli in docker k3d kubectl helm; do
  command -v "${cli}" >/dev/null 2>&1 || die "${cli} not found"
done
ok "all CLIs present"

step "Creating k3d cluster ${CLUSTER_NAME} (Flannel disabled)"
if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
  ok "cluster already exists, skipping creation"
else
  k3d cluster create --config "${REPO_ROOT}/cluster/k3d-config.yaml"
  ok "cluster created (nodes NotReady until CNI installed)"
fi

./scripts/install-cni.sh "${CNI}"

step "Running bootstrap.sh for the rest of the stack"
./scripts/bootstrap.sh

step "Applying NetworkPolicy"
kubectl apply -f "${REPO_ROOT}/manifests/network-policies.yaml"
ok "policies applied"

color_green ""
color_green "Lab ready with CNI ${CNI} + NetworkPolicy. Next:"
color_green "  make seed-services"
color_green "  make seed-electricity-maps     # optional"
color_green "  make up-gitlab                 # optional, GitLab CE inside the segmented cluster"
color_green "  make verify-network-policies   # confirm deny-by-default + allowed paths"
