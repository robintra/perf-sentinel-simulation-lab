#!/usr/bin/env bash
# B2-3 daemon OTLP direct - DEFERRED placeholder.
# See README.md for the planned implementation and resume instructions.

set -euo pipefail

cat <<'EOF'
B2-3 (daemon receives OTLP HTTP directly, no Collector)
Status: DEFERRED to follow-up session.

The first run in 2026-05-01 crashed the local k3d API server under
cumulative load. Resume requires a clean `make reset-cni` first, see
scenarios/b2-3-daemon-otlp-direct/README.md.

Skipping with exit 0.
EOF

exit 0
