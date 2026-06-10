#!/usr/bin/env bash
# Build a perf-sentinel daemon image from a local source checkout, import it
# into the k3d cluster, and pin the daemon manifest to it (working-tree edit,
# NOT committed). Pre-release validation flow: the maintainer replaces the
# pin with the GHCR digest once the release image exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
CLUSTER_NAME="${CLUSTER_NAME:-perf-sentinel-lab}"
MANIFEST="${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml"

[ -d "${PERF_SENTINEL_REPO_PATH}" ] || { echo "error: no perf-sentinel checkout at ${PERF_SENTINEL_REPO_PATH}" >&2; exit 1; }

VERSION="$(grep -m1 '^version' "${PERF_SENTINEL_REPO_PATH}/Cargo.toml" | sed 's/.*"\(.*\)"/\1/')"
TAG="perf-sentinel:${VERSION}-local"

echo "==> building ${TAG} from ${PERF_SENTINEL_REPO_PATH} (musl static, FROM scratch)"
docker build -q -f "${REPO_ROOT}/tools/daemon-image/Dockerfile" -t "${TAG}" "${PERF_SENTINEL_REPO_PATH}"

echo "==> importing ${TAG} into k3d cluster ${CLUSTER_NAME}"
k3d image import "${TAG}" -c "${CLUSTER_NAME}"

echo "==> pinning ${MANIFEST} to ${TAG} (uncommitted working-tree edit)"
python3 - "${MANIFEST}" "${TAG}" <<'PY'
import re
import sys

path, tag = sys.argv[1], sys.argv[2]
src = open(path).read()
out, n = re.subn(
    r"image: ghcr\.io/robintra/perf-sentinel@sha256:[0-9a-f]+(\s*#.*)?",
    f"image: {tag}  # local pre-release build, replace with the GHCR digest at release",
    src,
)
if n == 0 and f"image: {tag}" not in src:
    sys.exit("error: could not find the daemon image pin to replace")
if "imagePullPolicy" not in out:
    out = out.replace(
        f"image: {tag}  # local pre-release build, replace with the GHCR digest at release",
        f"image: {tag}  # local pre-release build, replace with the GHCR digest at release\n          imagePullPolicy: Never",
    )
open(path, "w").write(out)
PY

echo "==> applying and rolling the daemon"
kubectl apply -f "${MANIFEST}" >/dev/null
kubectl -n observability rollout status deploy/perf-sentinel-daemon --timeout=180s

echo "==> done. The manifest now carries an uncommitted local pin:"
git -C "${REPO_ROOT}" diff --stat -- manifests/perf-sentinel-daemon.yaml || true
