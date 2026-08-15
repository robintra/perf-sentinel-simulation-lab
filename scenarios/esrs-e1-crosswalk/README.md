# `esrs-e1-crosswalk` scenario

Locks the **0.8.13 gate R1**: the ESRS E1 datapoint crosswalk and the
`perf-sentinel-report/v1.3` schema bump, plus hash integrity and backward
compatibility.

Disclosing an internal report and asserts:

1. `schema_version == perf-sentinel-report/v1.3`.
2. `methodology.standard_crosswalk`: `standard` ~ `ESRS E1`, `mappings[].datapoint`
   reference `E1-5` / `Scope 2` / `Scope 3`, and a note/caveat mentions
   `market-based` (the location-based-only caveat).
3. `notes.disclaimers` carries the ESRS `standard_crosswalk … mapping aid` line.
4. integrity: `hash-bake` → `verify-hash` = `PARTIAL` / exit 2 with
   `[OK] Content hash` (unsigned). A tampered field → `[FAIL] Content hash`
   / exit 1.
5. retro-compat: a frozen **v1.2** example (`docs/schemas/examples/`) still
   validates against the v1.3 JSON Schema (`docs/schemas/perf-sentinel-report-v1.json`
   in the product repo). SKIPped if `check-jsonschema` or the schema is absent.

Hermetic CLI scenario (`analyze` → archived window → `disclose`, no daemon).

## Run

```
make verify-esrs-e1-crosswalk
PERF_SENTINEL_VERSION=0.8.13-rc make verify-esrs-e1-crosswalk   # pre-release
```

`PERF_SENTINEL_REPO_PATH` (default `~/RustroverProjects/perf-sentinel`) locates the
JSON Schema + v1.2 examples for the retro-compat check.

## Which binary this runs against

`scripts/resolve-image.sh` picks the image: `PERF_SENTINEL_IMAGE` (a full
reference, for a locally built pre-release), then `PERF_SENTINEL_VERSION` (a
GHCR tag), then the pin in `manifests/perf-sentinel-daemon.yaml`.

It used to default to a hardcoded old tag, so the scenario ran green on
every release without ever touching the version under validation. The gate
reported a PASS for code it had not executed. The 0.9.25 round is what
surfaced that, and the eight image scenarios now share this resolution.
