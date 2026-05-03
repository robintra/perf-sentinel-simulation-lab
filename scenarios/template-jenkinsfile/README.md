# Template Jenkinsfile validation

Validates the upstream `docs/ci-templates/jenkinsfile.groovy` template
at v0.5.17. Note that the upstream filename is lowercase
`jenkinsfile.groovy`, NOT `Jenkinsfile`. The Multibranch Pipeline plugin
accepts the `.groovy` extension for IDE syntax highlighting.

## Run

```bash
make verify-template-jenkinsfile

# Lint + structural only, skip jenkinsfile-runner:
SKIP_RUNTIME=1 make verify-template-jenkinsfile

# Override version:
UPSTREAM_VERSION=0.5.18 make verify-template-jenkinsfile

# Use a local copy:
UPSTREAM_PATH=~/perf-sentinel/docs/ci-templates/jenkinsfile.groovy \
  make verify-template-jenkinsfile
```

Report at `/tmp/scenario-template-jenkinsfile-report.md`.

## What it validates

1. **Fetch**. Curl upstream at v0.5.17, fallback to local clone.
2. **Structural lint**. Check that the declarative pipeline skeleton is
   present and well-formed:
   - `pipeline { ... }`
   - `stages { ... }` block
   - `perf-sentinel analyze` invocation
   - `--ci` quality-gate flag
   - SARIF output reference
   - `archiveArtifacts` step (warned if missing)
   - `PERF_SENTINEL_VERSION` pin (no floating tags)
3. **Best-effort runtime**. Pull `jenkins/jenkinsfile-runner:latest`
   container and execute the pipeline against a small fixture trace.
   This step is environment-fragile (Java init, plugin downloads,
   binary download from GitHub Releases). Failures are downgraded to
   SKIPPED with a clear note.

## Verdicts

- **PASS**: structural + runtime both PASS.
- **PARTIAL (runtime SKIPPED)**: structural PASS, runtime tolerantly
  skipped due to environment. Acceptable.
- **FAIL**: structural invariants missing (template upstream regression).

## Limitations

- The upstream Jenkinsfile downloads the Linux amd64 perf-sentinel
  binary from `github.com/robintra/perf-sentinel/releases/...`. If this
  release URL is not reachable from the runner, the runtime stage of
  the Jenkinsfile will fail. This is a property of the template's
  install pattern, not a defect of the lab.
- `jenkins/jenkinsfile-runner` images are sometimes stale on Docker
  Hub. The scenario tolerates pull failures.
- Default 5 min timeout on the runtime step; bump via `JFR_IMAGE` and
  bash hacking if you need more.

## Files

| File | Purpose |
| --- | --- |
| `verify.sh` | Fetch + structural + best-effort runtime |
| `.perf-sentinel.toml` | Strict thresholds (matches ci-shift-left) |
