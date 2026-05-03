# Template GitHub Actions validation

Validates the upstream `docs/ci-templates/github-actions.yml` workflow
at v0.5.17. Structural lint + best-effort `act --list` parse check.

## Run

```bash
make verify-template-github-actions

# Lint + structural only:
SKIP_RUNTIME=1 make verify-template-github-actions

# Override version:
UPSTREAM_VERSION=0.5.18 make verify-template-github-actions

# Use a local copy:
UPSTREAM_PATH=~/perf-sentinel/docs/ci-templates/github-actions.yml \
  make verify-template-github-actions
```

Report at `/tmp/scenario-template-github-actions-report.md`.

## What it validates

1. **Fetch**. Curl upstream at v0.5.17, fallback to local clone.
2. **Structural lint**:
   - YAML parses (python `yaml.safe_load`).
   - Top-level keys present: `name`, `on`, `permissions`, `jobs`.
   - perf-sentinel binary install step (release URL pattern).
   - `perf-sentinel analyze` step.
   - `--ci` quality-gate flag.
   - `github/codeql-action/upload-sarif` step.
   - `uses:` declarations pinned to 40-character commit SHAs (no
     floating tags). Warning if any are unpinned.
   - Quality gate enforcement step.
   - PR comment + sticky comment plugin presence.
3. **act --list**. Run `nektos/act --list` against the workflow to
   confirm act parses it without errors. No actual job execution
   (would require GitHub Pages, secrets, gh-pages branch). Failures
   downgrade to SKIPPED with a clear note.

## Verdicts

- **PASS**: structural + act --list both PASS.
- **PARTIAL**: structural PASS, act SKIPPED. Acceptable.
- **FAIL**: YAML parse fails OR a required step is missing.

## Limitations

- `act` cannot fully simulate GitHub Actions (secrets, gh-pages
  pushes, third-party Actions like
  `marocchino/sticky-pull-request-comment` may fail in local
  containers). Only `act --list` is run, which confirms the workflow
  parses cleanly.
- The template's binary install step downloads from
  `github.com/robintra/perf-sentinel/releases/...`. Real workflow runs
  in GHA depend on this URL being reachable and the release artefact
  being present. The lab does not validate the binary's actual
  download here.
- act image pull failures (network, image deprecated) are tolerated.

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Fetch + structural + act --list |
| `.perf-sentinel.toml` | Strict thresholds (matches ci-shift-left) |
