#!/usr/bin/env bash
# Build and deploy the three Java services into the shop namespace.
# Usage: ./scripts/seed-services.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CLUSTER_NAME="perf-sentinel-lab"
SERVICES=(order-service payment-service notification-service)
TAG="s2"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PASSWORD_FILE="${REPO_ROOT}/.postgres-password"
if [ ! -f "${PASSWORD_FILE}" ]; then
  die "missing .postgres-password (run make up first)"
fi

step "Building Docker images for ${SERVICES[*]}"
for svc in "${SERVICES[@]}"; do
  docker build -q \
    -f "${REPO_ROOT}/services/shared-dockerfile/Dockerfile" \
    --build-arg SERVICE_NAME="${svc}" \
    -t "${svc}:${TAG}" \
    "${REPO_ROOT}/services/" >/dev/null
  ok "${svc}:${TAG} built"
done

step "Importing images into k3d cluster ${CLUSTER_NAME}"
for svc in "${SERVICES[@]}"; do
  if k3d image import "${svc}:${TAG}" -c "${CLUSTER_NAME}" >/dev/null 2>&1; then
    ok "${svc}:${TAG} imported"
  else
    color_red "    warn: import failed for ${svc}, kubelets will fall back to image pull"
  fi
done

step "Helm upgrade --install for the 3 charts"
for svc in "${SERVICES[@]}"; do
  # --set-file reads the password from disk so it never appears in argv
  # (visible to ps aux) or shell history.
  helm upgrade --install "${svc}" "${REPO_ROOT}/services/${svc}/helm/" \
    -n shop \
    --set-file "database.password=${PASSWORD_FILE}" \
    --wait --timeout 5m >/dev/null
  ok "${svc} deployed"
done

step "Waiting for shop deployments"
kubectl wait deployment --all -n shop \
  --for=condition=Available --timeout=180s

step "Services ready"
kubectl get pods -n shop
