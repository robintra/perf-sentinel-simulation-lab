#!/usr/bin/env bash
# Confirm the Electricity Maps integration is wired end-to-end:
#   1. Secret perf-sentinel-electricity-maps exists in observability.
#   2. The daemon Deployment mounts PERF_SENTINEL_EMAPS_TOKEN.
#   3. The daemon export endpoint surfaces a non-null green_summary.scoring_config.
# Usage: ./scripts/verify-electricity-maps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="observability"
SECRET_NAME="perf-sentinel-electricity-maps"
DEPLOY_NAME="perf-sentinel-daemon"
DAEMON_SERVICE="perf-sentinel-daemon"
DAEMON_PORT="14318"
ENV_VAR="PERF_SENTINEL_EMAPS_TOKEN"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

step "Checking secret ${NAMESPACE}/${SECRET_NAME}"
if ! kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o name >/dev/null 2>&1; then
  die "secret not found. Run make seed-electricity-maps."
fi
ok "secret present"

step "Checking ${ENV_VAR} mounted on ${DEPLOY_NAME}"
ENV_DUMP="$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOY_NAME}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="perf-sentinel")].env[*].name}')"
if ! grep -q "${ENV_VAR}" <<<"${ENV_DUMP}"; then
  die "${ENV_VAR} is not in the daemon spec. The manifest may be stale: kubectl apply -f manifests/perf-sentinel-daemon.yaml"
fi
ok "env var declared in deployment spec"

step "Querying scoring_config from the daemon export endpoint"
kubectl -n "${NAMESPACE}" port-forward "svc/${DAEMON_SERVICE}" "${DAEMON_PORT}:${DAEMON_PORT}" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  if curl -fsS "http://localhost:${DAEMON_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! curl -fsS "http://localhost:${DAEMON_PORT}/health" >/dev/null 2>&1; then
  die "daemon never became reachable on localhost:${DAEMON_PORT}"
fi

SCORING_LINE="$(curl -fsS "http://localhost:${DAEMON_PORT}/api/export/report" \
  | python3 -c "
import json, sys
report = json.load(sys.stdin)
sc = report.get('green_summary', {}).get('scoring_config')
if not sc:
    sys.stderr.write('scoring_config is null. Token rejected or daemon not picking up env var.\n')
    sys.exit(1)
print(f\"Electricity Maps {sc.get('api_version', '?')}, {sc.get('emission_factor_type', '?')}, {sc.get('temporal_granularity', '?')}\")
")"
ok "${SCORING_LINE}"

color_green ""
color_green "Electricity Maps integration: ACTIVE"
color_green "  endpoint:           https://api.electricitymaps.com/v4"
color_green "  emission factor:    direct"
color_green "  temporal grain:     5_minutes (sandbox coarsens to hourly)"
color_green "  zone map:           eu-west-3 -> FR"
