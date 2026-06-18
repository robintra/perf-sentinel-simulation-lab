# `verify-hash-fail-closed` scenario

Locks the **0.8.13 gate R2**: `verify-hash` fails closed on a report that carries
`integrity.signature` but is verified **without** `--expected-identity` /
`--expected-issuer` (and without `--no-identity-check`).

The identity gate short-circuits **before** cosign, so:

- exit code `1` / `Overall: UNTRUSTED`
- `[FAIL] Signature` ("cannot verify without expected identity …")
- `[OK] Content hash` — the canonical hash blanks the signature, so adding it
  does not invalidate the content hash.

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
