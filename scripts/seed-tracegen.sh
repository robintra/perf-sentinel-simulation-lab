#!/usr/bin/env bash
# Build the tracegen load-generator image and import it into the k3d
# cluster. Mirrors the multistack seed scripts: build on the host, import,
# never pull in-cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-perf-sentinel-lab}"
TAG="lab-tracegen:1"

echo "==> building ${TAG}"
docker build -q -t "${TAG}" "${REPO_ROOT}/tools/tracegen"

echo "==> importing ${TAG} into k3d cluster ${CLUSTER_NAME}"
k3d image import "${TAG}" -c "${CLUSTER_NAME}"

echo "==> done: ${TAG}"
