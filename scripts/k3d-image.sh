#!/usr/bin/env bash
# Shared k3d helpers sourced by scripts/seed-services.sh and
# scripts/bootstrap.sh. No top-level side effects, only function
# definitions, so the file is safe to source more than once.

# verify_k3d_image_on_all_nodes <cluster> <image>
#
# Confirms that <image> is loaded into containerd on every k3d
# worker node (server + agent roles, loadbalancer excluded) of
# <cluster>. Prints diagnostic context to stdout when the check
# fails (either the names of nodes still missing the image, or a
# message identifying that no nodes were enumerable at all) and
# returns 1. Returns 0 only when at least one node was inspected
# and all of them have the image.
#
# Image matching uses fixed-string substring grep, which is robust
# to containerd's prefix variations (e.g. docker.io/library/...)
# and avoids regex injection on caller-supplied image names.
verify_k3d_image_on_all_nodes() {
  local cluster="$1" image="$2" node missing=() checked=0
  while read -r node; do
    [ -z "${node}" ] && continue
    checked=$((checked + 1))
    if ! docker exec "${node}" ctr -n k8s.io images list -q 2>/dev/null \
        | grep -qF "${image}"; then
      missing+=("${node}")
    fi
  done < <(k3d node list --no-headers 2>/dev/null \
            | awk -v c="${cluster}" '$2 ~ /^(server|agent)$/ && $3 == c {print $1}')
  if [ "${checked}" -eq 0 ]; then
    # Either no cluster, or `k3d node list` failed, or `docker exec`
    # cannot reach the daemon. The caller should treat this as an
    # environment issue, not a missing-image one.
    echo "no k3d worker node enumerable for cluster ${cluster}"
    return 1
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}
