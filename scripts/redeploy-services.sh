#!/usr/bin/env bash
# Re-apply Helm values for the 3 Java services without rebuilding the
# Docker images. Use this after editing services/*/helm/values.yaml
# (e.g. to flip cloud.region) to pick up the change without going
# through the full seed-services build cycle.
# Usage: ./scripts/redeploy-services.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SERVICES=(order-service payment-service notification-service)

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

step "Helm upgrade --install for the 3 charts"
# This deliberately re-evaluates each chart's values.yaml from scratch.
# Any ad-hoc `helm upgrade --set otel.cloudRegion=us-east-1` overrides
# applied previously will be reset to the value baked into the chart
# directory. That is the lab's intended behaviour: values.yaml in the
# repo is the source of truth. Use `--reuse-values` here instead if you
# need to preserve out-of-band overrides between redeploys.
for svc in "${SERVICES[@]}"; do
  helm upgrade --install "${svc}" "${REPO_ROOT}/services/${svc}/helm/" \
    -n shop \
    --set-file "database.password=${PASSWORD_FILE}" \
    --wait --timeout 5m >/dev/null
  ok "${svc} upgraded"
done

step "Rolling restart to pick up env var changes"
for svc in "${SERVICES[@]}"; do
  kubectl -n shop rollout restart "deployment/${svc}" >/dev/null
done

step "Waiting for shop deployments"
kubectl wait deployment --all -n shop \
  --for=condition=Available --timeout=180s

step "Services ready"
kubectl get pods -n shop
