#!/usr/bin/env bash
# Install Cilium 1.17.6 on a freshly created k3d cluster (Flannel
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
CILIUM_VERSION="1.17.6"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

case "${CNI}" in
  cilium)
    step "Installing Cilium ${CILIUM_VERSION} via Helm"
    helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
    helm repo update cilium >/dev/null

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
    helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
    helm repo update projectcalico >/dev/null
    helm upgrade --install calico projectcalico/tigera-operator \
      --namespace tigera-operator --create-namespace \
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
