# verify-hash-roundtrip

CLI contract regression scenario for `perf-sentinel verify-hash`, locking the
v0.7.0 breaking change (identity flags required by default, exit codes
redesigned to 0/1/2/3/4).

## What it covers

5 sub-tests run inside `ghcr.io/robintra/perf-sentinel:${PERF_SENTINEL_VERSION}`
(defaults to the lab's currently-pinned version):

1. **Placeholder hash detection** (exit 1, UNTRUSTED).
   The upstream `docs/schemas/examples/example-official-public-G2.json`
   ships with a zeroed `integrity.content_hash` placeholder. Running
   `verify-hash --report` against it must recompute, mismatch, and exit 1
   with `[FAIL] Content hash` on stdout.

2. **Missing report INPUT_ERROR** (exit 3).
   Distinct exit code from a tamper (exit 1) so wrapper scripts can
   react differently to a wrong path than to a forged report.

3. **HTTP URL NETWORK_ERROR** (exit 4).
   HTTPS-only hardening. `--url http://...` must be rejected before any
   network call. Distinct exit code from INPUT_ERROR (exit 3).

4. **Identity-required default** (exit 1, breaking-change error string).
   With `integrity.signature` populated and no `--expected-identity` /
   `--expected-issuer` / `--no-identity-check` passed, verify-hash must
   refuse with the grep-stable string `cannot verify without expected
   identity`. This is the v0.7.0 breaking change: a Sigstore bundle
   without an identity constraint can be forged by any GitHub or Google
   account holder, so the CLI now requires the operator to opt out
   explicitly with `--no-identity-check`.

5. **Half-pair rejection** (exit 1).
   Passing only one of the `--expected-identity` / `--expected-issuer`
   pair must fail with the grep-stable string `both --expected-identity
   and --expected-issuer must be passed together`. Prevents accidental
   single-flag use that would silently downgrade verification.

## Coverage gaps tracked

- **exit 0 (TRUSTED) end-to-end roundtrip**: requires a fixture with the
  canonical content hash baked in. Today this hash is only computable
  through the in-process Rust API `compute_content_hash()`; there is no
  CLI surface (`disclose` produces a Report but requires a full archive
  + org-config, not friendly to a 5-sub-test scenario). When a CLI
  helper like `perf-sentinel hash-bake --report <in> --output <out>`
  ships upstream, add a 6th sub-test.

- **exit 2 (PARTIAL) on hash-valid + signature-absent**: same
  prerequisite. Today the placeholder example exits 1 because the hash
  itself fails to validate; with a baked hash + no signature block the
  CLI would return 2 and we could lock that mapping too.

## Runtime

CLI-only, ~10 seconds. No cluster contact, no daemon dependency.

Dependencies: `docker`, `jq`.

## Reproducibility

```
PERF_SENTINEL_VERSION=0.7.1 ./scenarios/verify-hash-roundtrip/verify.sh
```

The fixture under `fixtures/example-official-public-G2.json` is a
verbatim copy of the upstream example at
`docs/schemas/examples/example-official-public-G2.json`. If the upstream
example evolves, refresh the fixture with:

```
cp "${PERF_SENTINEL_REPO_PATH}/docs/schemas/examples/example-official-public-G2.json" \
   scenarios/verify-hash-roundtrip/fixtures/example-official-public-G2.json
```
