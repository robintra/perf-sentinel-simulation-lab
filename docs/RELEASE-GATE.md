# Lab validation release gate

This document specifies a release-gate contract between the
perf-sentinel upstream repo and this simulation lab: no perf-sentinel
version should be tagged for public release without a recent PASS in
the lab's end-to-end validation suite.

## Why

Between v0.6.1 and v0.7.1, three perf-sentinel versions (v0.6.2, v0.7.0,
v0.7.1) shipped to GitHub Releases, crates.io, GHCR, and the Helm chart
without ever passing through this lab. The drift was discovered during
the v0.7.1 retrospective validation on 2026-05-15. v0.7.1 ultimately
passed, but the operator inherited two retries of the full suite to
sort out lab-side gaps. The risk profile of "lab unaware of N releases"
grows with N: a regression that survives all upstream unit tests can
ship for weeks before anyone notices.

Making lab PASS a release pre-flight requirement closes that loop.

## Architecture

Two artefacts live in this lab repo and are designed to migrate to the
upstream perf-sentinel repo when ready:

- `release-gate/check-lab-validation.sh`: the gate script. Reads a
  ledger file and exits 0 iff a recent PASS exists for the target
  version. Has no dependency on this lab beyond bash, awk, and `date`,
  so it ports cleanly.
- `scripts/record-validation.sh`: the lab-side helper. After a
  validation completes, the operator runs it to print a tab-separated
  line for the ledger. The operator then pastes this line into the
  upstream ledger.

The ledger file `lab-validations.txt` lives in the upstream perf-sentinel
repo (target path TBD: probably `release-gate/lab-validations.txt` or
`docs/lab-validations.txt`), versioned alongside the source.

## Ledger format

One validation per line. Tab-separated. Empty lines and lines starting
with `#` are ignored.

```
<version>\t<lab_commit_sha>\t<YYYY-MM-DD>\t<PASS|FAIL>
```

- `version`: the exact perf-sentinel version validated, like `v0.7.1`.
  Must start with `v`.
- `lab_commit_sha`: the simulation-lab repo HEAD short SHA at the time
  of validation. Lets a future reader replay the validation against the
  same lab state (relevant if the lab itself evolves).
- `YYYY-MM-DD`: UTC date of the validation.
- `verdict`: `PASS` or `FAIL`. Only PASS entries are accepted by the
  gate. FAIL entries are recorded for audit but never green-light a
  release.

Example:
```
# perf-sentinel lab validation ledger
v0.6.1	5c041bb	2026-05-09	PASS
v0.7.1	0eeceb4	2026-05-15	PASS
v0.7.2	1cdb2d0	2026-05-15	PASS
```

## Operator workflow

After running a lab validation (typically `make verify-all-scenarios`
plus the documented retries for any flaky scenario):

1. Determine the verdict. PASS only if every genuine regression is
   absent (per the lab's failure-analysis taxonomy: flake, obsolete
   test, infra, or regression).
2. From the lab repo:
   ```
   scripts/record-validation.sh v0.7.2 PASS
   ```
   This prints a single tab-separated line.
3. Append the line to the upstream `lab-validations.txt` and commit it
   in the upstream repo with a subject like `chore: record v0.7.2 lab
   validation`.

Before tagging a release upstream:

```
release-gate/check-lab-validation.sh --version v0.7.2
```

Exit 0 means safe to tag. Exit 1 prints the actionable reason (no
entry, FAIL entry only, or stale entry past the age threshold).

## Age threshold

Default: 30 days. Configurable via `--max-age-days N`. Justification:
the lab cluster definition (Cilium version, k3d version, Java service
images, Tempo / Prometheus / Grafana versions, etc.) drifts over time
through normal dependency updates. A PASS validation from six months
ago says little about today's lab and even less about today's release.

Operators can override per release if a freshly-bumped lab is not
practical, but doing so should be documented in the release notes
(e.g. "validated against lab snapshot from 35 days ago, judged
acceptable because no lab manifest changed since").

## Wiring upstream

Suggested addition to the perf-sentinel release checklist (in
`docs/release-process.md` or equivalent), at the pre-tag step:

> Before pushing the version tag, run `release-gate/check-lab-validation.sh
> --version vX.Y.Z`. If it exits non-zero, run the simulation lab
> against this version, record the verdict, append the ledger line,
> and retry the gate. Do not tag until the gate exits 0.

## Out of scope

- Automating the lab run from the upstream side (one-click validation).
  Today the lab is a manual environment. A future iteration could ship
  a GitHub Action that runs the lab against a candidate version, but
  the underlying k3d cluster requires ~10 min of bootstrap and is not
  practical in a typical CI runner without warm caching.
- Cryptographic attestation of ledger entries (signing each line).
  Today the trust model is "the operator commits the line, code review
  validates it". An attestation flow would require a sigstore keypair
  scoped to the lab, which is more infrastructure than the value
  currently justifies.
