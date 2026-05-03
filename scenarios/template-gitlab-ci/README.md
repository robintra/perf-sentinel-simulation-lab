# Template GitLab CI validation

Validates the upstream `docs/ci-templates/gitlab-ci.yml` template at
v0.5.17 against the in-cluster GitLab CE. Lint + parity + delegation to
the existing `scripts/verify-gitlab-perf-sentinel.sh` end-to-end check.

## Run

```bash
make verify-template-gitlab-ci

# Override version:
UPSTREAM_VERSION=0.5.18 make verify-template-gitlab-ci

# Use a local copy (offline):
UPSTREAM_PATH=~/perf-sentinel/docs/ci-templates/gitlab-ci.yml \
  make verify-template-gitlab-ci

# Lint + parity only, skip the heavy end-to-end:
SKIP_E2E=1 make verify-template-gitlab-ci
```

Report at `/tmp/scenario-template-gitlab-ci-report.md`.

## What it validates

1. **Fetch**. Curl the upstream template at v0.5.17 (fallback to local
   clone at `~/RustroverProjects/perf-sentinel/` if curl fails).
2. **Lint via GitLab CE CI Lint API**. POST the YAML to
   `/api/v4/ci/lint`, asserts `valid: true`. Catches schema regressions
   that `bash -n` and yq cannot detect (gitlab-specific keywords).
3. **Parity vs lab fixture**. Compares structural invariants between
   the upstream and `artifacts/fixtures/gitlab-ci-from-upstream.yml`:
   - `perf-sentinel:` job declared
   - `--ci` flag present (quality gate enforced)
   - SARIF artifact declared
   - PERF_SENTINEL_VERSION variable pinned (no floating tags)
   The lab fixture is intentionally a derivative (adds an
   `integration-tests` dummy job and uncomments the Free-tier Pages
   block), so byte-identity is not the goal.
4. **End-to-end**. Delegates to
   `scripts/verify-gitlab-perf-sentinel.sh` which:
   - clones the seeded `perf-sentinel-template-test` GitLab project,
   - pushes a commit on `main` and asserts the pipeline ends in
     `success` (gate `allow_failure: true` on default branch),
   - opens an MR and asserts the pipeline ends in `failed` (gate
     enforced on MR via `allow_failure: false`),
   - downloads SARIF + perf-sentinel-report.json + Code Quality
     artefacts and asserts they parse and contain the expected schema.

## Verdicts

- **PASS**: lint + parity + E2E all PASS.
- **PARTIAL**: lint or E2E SKIPPED (e.g. GitLab CE not deployed), but
  parity PASS. Acceptable for a CI run that does not bring up GitLab.
- **FAIL**: any hard step fails (lint rejects, parity invariants
  missing, or E2E pipeline produces wrong status).

## Limitations

- The lab fixture pins an older version (currently 0.5.14, may drift).
  This scenario does not auto-bump the fixture; that stays a deliberate
  decision.
- `verify-gitlab-perf-sentinel.sh` requires `make up-gitlab && make
  seed-gitlab-project` to have run beforehand. If the fixture project
  doesn't exist yet, the E2E step skips with a clear message.
- The end-to-end run takes ~5-10 min wall clock (GitLab pipeline runs
  the analyzer twice, once on main and once on the MR).

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Lint + parity + E2E delegation |
| `.perf-sentinel.toml` | Strict thresholds (matches ci-shift-left) |
