#!/usr/bin/env bash
# Release-gate pre-flight: assert a recent PASS lab validation exists for
# a perf-sentinel version before tagging it for public release.
#
# Designed to live in the perf-sentinel upstream repo (e.g. as
# `release-gate/check-lab-validation.sh`) and to be invoked from the
# release checklist. Today it lives in the simulation-lab repo as a
# portable artefact pending manual migration upstream.
#
# Reads a tab-separated `lab-validations.txt` ledger. One line per
# validation:
#   <version>\t<lab_commit_sha>\t<YYYY-MM-DD>\t<PASS|FAIL>
#
# Lines starting with `#` and empty lines are ignored.
#
# Exits 0 if the target version has at least one PASS entry no older
# than `--max-age-days` (default 30). Exits 1 with an actionable message
# otherwise.

set -euo pipefail

VERSION=""
LEDGER="${LEDGER:-lab-validations.txt}"
MAX_AGE_DAYS=30

usage() {
  cat <<EOF
Usage: $(basename "$0") --version vX.Y.Z [--ledger PATH] [--max-age-days N]

Asserts that a PASS lab validation exists for the requested version in
the ledger, dated within the last N days. Defaults: ledger=lab-validations.txt,
max-age-days=30.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)      VERSION="${2:?--version requires an argument}"; shift 2 ;;
    --ledger)       LEDGER="${2:?--ledger requires an argument}"; shift 2 ;;
    --max-age-days) MAX_AGE_DAYS="${2:?--max-age-days requires an argument}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "${VERSION}" ] || { echo "missing --version" >&2; usage >&2; exit 2; }

if [ ! -f "${LEDGER}" ]; then
  echo "release-gate: ledger ${LEDGER} not found." >&2
  echo "Run a lab validation, then use scripts/record-validation.sh in the lab repo to produce a line to append here." >&2
  exit 1
fi

# Portable "today minus N days" in seconds-since-epoch. Supports BSD and GNU date.
today_epoch="$(date -u +%s)"
cutoff_epoch=$(( today_epoch - MAX_AGE_DAYS * 86400 ))

# Find the most recent PASS line for the requested version.
match="$(awk -F '\t' -v ver="${VERSION}" '
  /^#/ { next }
  NF >= 4 && $1 == ver && $4 == "PASS" { print $0 }
' "${LEDGER}")"

if [ -z "${match}" ]; then
  echo "release-gate: no PASS entry for ${VERSION} in ${LEDGER}." >&2
  echo "Run the lab against ${VERSION}, append a PASS line via scripts/record-validation.sh, then retry." >&2
  exit 1
fi

# Keep the latest by date (column 3) in case of multiple entries.
latest_line="$(printf '%s\n' "${match}" | sort -t$'\t' -k3 | tail -1)"
latest_date="$(printf '%s' "${latest_line}" | awk -F '\t' '{print $3}')"
latest_sha="$(printf '%s' "${latest_line}" | awk -F '\t' '{print $2}')"

# Convert YYYY-MM-DD to epoch (UTC midnight). BSD date uses -j -f, GNU uses -d.
if latest_epoch="$(date -u -j -f "%Y-%m-%d" "${latest_date}" +%s 2>/dev/null)"; then
  :
elif latest_epoch="$(date -u -d "${latest_date}" +%s 2>/dev/null)"; then
  :
else
  echo "release-gate: cannot parse date '${latest_date}' from ledger." >&2
  exit 1
fi

if [ "${latest_epoch}" -lt "${cutoff_epoch}" ]; then
  age_days=$(( (today_epoch - latest_epoch) / 86400 ))
  echo "release-gate: latest PASS for ${VERSION} is ${age_days} days old (lab commit ${latest_sha}, ${latest_date})." >&2
  echo "Threshold is ${MAX_AGE_DAYS} days. Re-run the lab against ${VERSION} and record a fresh entry." >&2
  exit 1
fi

age_days=$(( (today_epoch - latest_epoch) / 86400 ))
echo "release-gate: PASS for ${VERSION} dated ${latest_date} (lab commit ${latest_sha}, ${age_days}d old, threshold ${MAX_AGE_DAYS}d). OK to release."
exit 0
