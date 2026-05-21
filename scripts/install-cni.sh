#!/usr/bin/env bash
# Install Cilium 1.19.3 on a freshly created k3d cluster (Flannel
# disabled in cluster/k3d-config.yaml). Calico is documented as a
# manual fallback in case Cilium does not stabilize on Docker Desktop
# arm64. The active CNI name is written to cluster/.cni-active so
# downstream scripts can adapt their CRD apiVersion.
#
# Usage: ./scripts/install-cni.sh [cilium|calico]
#   default: cilium
#
# kubeProxyReplacement is left at its default value (false) because
# Docker Desktop's host networking layer is not stable enough to host
# Cilium's full kube-proxy replacement on arm64. The lab keeps the
# k3s-bundled kube-proxy and lets Cilium run alongside it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CNI="${1:-cilium}"
CNI_MARKER="${REPO_ROOT}/cluster/.cni-active"
CILIUM_VERSION="1.19.3"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

case "${CNI}" in
  cilium)
    step "Installing Cilium ${CILIUM_VERSION} via Helm"
    # Add the cilium repo with retries. helm.cilium.io occasionally
    # returns 5xx or times out from GitHub-hosted runners and the
    # previous `|| true` swallowed those errors, leaving the next
    # `helm repo update` to fail loudly with "no repositories matching
    # 'cilium'" (observed on scheduled run 26202794690, 2026-05-21).
    add_attempts=3
    for attempt in $(seq 1 "${add_attempts}"); do
      if helm repo add cilium https://helm.cilium.io; then
        break
      fi
      if [ "${attempt}" -eq "${add_attempts}" ]; then
        die "helm repo add cilium failed after ${add_attempts} attempts"
      fi
      color_red "    helm repo add cilium attempt ${attempt}/${add_attempts} failed, retrying in 5s"
      sleep 5
    done
    helm repo update cilium

    helm upgrade --install cilium cilium/cilium \
      --namespace kube-system \
      --version "${CILIUM_VERSION}" \
      --set kubeProxyReplacement=false \
      --set hubble.enabled=true \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=false \
      --wait --timeout 5m

    step "Waiting for Cilium agents Ready"
    kubectl -n kube-system rollout status daemonset/cilium --timeout=120s
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=120s
    ok "Cilium ${CILIUM_VERSION} ready"
    printf 'cilium\n' > "${CNI_MARKER}"
    ;;
  calico)
    step "Installing Calico via tigera-operator (fallback path)"
    # NOTE: this path is documented but not exercised end-to-end in
    # this lab. Tigera operator alone does not bring Calico up; you
    # also need to apply an `Installation` custom resource (cf.
    # https://docs.tigera.io/calico/latest/getting-started/kubernetes/helm).
    # The current implementation installs the operator only; flesh
    # out the Installation CR before running this branch in anger.
    helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
    helm repo update projectcalico >/dev/null
    helm upgrade --install calico projectcalico/tigera-operator \
      --namespace tigera-operator --create-namespace \
      --version v3.32.0 \
      --wait --timeout 5m
    step "Waiting for Calico nodes Ready"
    kubectl -n calico-system rollout status daemonset/calico-node --timeout=180s
    ok "Calico ready"
    printf 'calico\n' > "${CNI_MARKER}"
    ;;
  *)
    die "unsupported CNI: ${CNI}. Pass cilium or calico."
    ;;
esac

color_green ""
color_green "CNI active: ${CNI} (marker: ${CNI_MARKER})"
color_green "Next: ./scripts/bootstrap.sh, then make apply-network-policies"
