#!/usr/bin/env bash
# Remove the three Java services. Cluster, observability and db remain.
set -euo pipefail

SERVICES=(order-service payment-service notification-service)

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }

step "Helm uninstalling shop services"
for svc in "${SERVICES[@]}"; do
  if helm status "${svc}" -n shop >/dev/null 2>&1; then
    helm uninstall "${svc}" -n shop >/dev/null
    ok "${svc} uninstalled"
  else
    ok "${svc} not installed, skipping"
  fi
done

step "Services removed"
