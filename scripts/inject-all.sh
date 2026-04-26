#!/usr/bin/env bash
# Lightweight wrapper: just run validate-findings.sh which already
# orchestrates Job creation, k6 execution, and findings assertion.
exec "$(dirname "${BASH_SOURCE[0]}")/validate-findings.sh" "$@"
