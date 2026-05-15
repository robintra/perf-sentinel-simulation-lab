#!/usr/bin/env bash
# Helper to produce a tab-separated line for the upstream perf-sentinel
# `lab-validations.txt` ledger after a lab validation completes. Prints
# one line on stdout. The operator copies it into the upstream ledger.
#
# Line format:
#   <version>\t<lab_commit_sha>\t<YYYY-MM-DD>\t<PASS|FAIL>
#
# Example:
#   $ scripts/record-validation.sh v0.7.1 PASS
#   v0.7.1\t0eeceb4\t2026-05-15\tPASS

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <version> <verdict>

  <version>   perf-sentinel version like vX.Y.Z (must start with 'v').
  <verdict>   PASS or FAIL.

Resolves the current lab repo HEAD short SHA and UTC date, then prints
one tab-separated line for the upstream lab-validations.txt ledger.
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 2
fi

VERSION="$1"
VERDICT="$2"

if [[ ! "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "version must match vX.Y.Z, got: ${VERSION}" >&2
  exit 2
fi

case "${VERDICT}" in
  PASS|FAIL) ;;
  *) echo "verdict must be PASS or FAIL, got: ${VERDICT}" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
DATE="$(date -u +%Y-%m-%d)"

printf '%s\t%s\t%s\t%s\n' "${VERSION}" "${SHA}" "${DATE}" "${VERDICT}"
