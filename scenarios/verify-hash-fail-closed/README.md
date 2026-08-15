# `verify-hash-fail-closed` scenario

Locks the **0.8.13 gate R2**: `verify-hash` fails closed on a report that carries
`integrity.signature` but is verified **without** `--expected-identity` /
`--expected-issuer` (and without `--no-identity-check`).

The identity gate short-circuits **before** cosign, so:

- exit code `1` / `Overall: UNTRUSTED`
- `[FAIL] Signature` ("cannot verify without expected identity …")
- `[OK] Content hash`: the canonical hash blanks the signature, so adding
  it does not invalidate the content hash.

No cosign binary is required (the gate fires first). This guards against a
Sigstore bundle forgeable by any GitHub/Google account holder.

Hermetic: `analyze` → archived window → `disclose` → `hash-bake` builds a valid
baked report, then a fake `SignatureMetadata` block is injected and `verify-hash`
is run with no identity flags.

## Run

```
make verify-verify-hash-fail-closed
PERF_SENTINEL_VERSION=0.8.13-rc make verify-verify-hash-fail-closed   # pre-release
```

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran green on
every release without ever touching the version under validation. The gate
reported a PASS for code it had not executed. The 0.9.25 round is what
surfaced that, and the eight image scenarios now share this resolution.
