#!/usr/bin/env bash
# Provision the Electricity Maps token Secret consumed by perf-sentinel.
# Reads the token from .electricity-maps-token at the repo root and creates
# (or updates) the `perf-sentinel-electricity-maps` Secret in the
# `observability` namespace, then rolls the daemon to pick up the env var.
# Usage: ./scripts/seed-electricity-maps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="observability"
SECRET_NAME="perf-sentinel-electricity-maps"
TOKEN_FILE="${REPO_ROOT}/.electricity-maps-token"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

if [ ! -f "${TOKEN_FILE}" ]; then
  die "missing ${TOKEN_FILE}. Save your Electricity Maps token (sandbox or trial) into that file then re-run."
fi

if [ ! -s "${TOKEN_FILE}" ]; then
  die "${TOKEN_FILE} is empty."
fi

# Warn if the token file is world-readable. The Secret in Kubernetes is
# the authoritative copy, but the on-disk file ends up there if anything
# ever logs the bootstrap output, so 0600 is the right default.
TOKEN_MODE="$(stat -f '%Lp' "${TOKEN_FILE}" 2>/dev/null || stat -c '%a' "${TOKEN_FILE}" 2>/dev/null || echo "?")"
if [ "${TOKEN_MODE}" != "600" ] && [ "${TOKEN_MODE}" != "?" ]; then
  color_red "    warn: ${TOKEN_FILE} mode is ${TOKEN_MODE}, expected 600 (run: chmod 600 ${TOKEN_FILE})"
fi

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  die "namespace ${NAMESPACE} not found. Run make up first."
fi

# Strip a trailing newline if present. The Electricity Maps API rejects
# tokens with whitespace silently (401), and `echo > file` is a common
# enough mistake that a defensive strip is worth more than the
# alternative (debug a mysterious fallback to `annual`).
STRIPPED_TOKEN_FILE="$(mktemp)"
trap 'rm -f "${STRIPPED_TOKEN_FILE}"' EXIT
# `tr -d` removes every newline and carriage return, no `printf` quoting
# concerns. The token is base64-ish so newlines never legitimately appear.
tr -d '\n\r' < "${TOKEN_FILE}" > "${STRIPPED_TOKEN_FILE}"
chmod 600 "${STRIPPED_TOKEN_FILE}"

step "Applying secret ${NAMESPACE}/${SECRET_NAME}"
kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-file=token="${STRIPPED_TOKEN_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "secret applied"

step "Rolling perf-sentinel-daemon to pick up the token"
kubectl -n "${NAMESPACE}" rollout restart deployment/perf-sentinel-daemon >/dev/null
kubectl -n "${NAMESPACE}" rollout status deployment/perf-sentinel-daemon --timeout=120s >/dev/null
ok "daemon ready with PERF_SENTINEL_EMAPS_TOKEN mounted"

color_green "Secret provisioned. Run make verify-electricity-maps to confirm."
