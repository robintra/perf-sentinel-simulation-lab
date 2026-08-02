# ci-e2e-jenkins

The documented Java CI recipe run inside a **real Jenkins**, from the Maven
integration test all the way to whether the published dashboard actually renders
in a browser.

> Quarantined out of the gate from 2026-08-01 to 2026-08-02 on J0. Product
> 0.9.25 fixed it and the scenario is back in `make verify-all-scenarios`.
> See *What it found*.

## Why it exists

A user reported a perf-sentinel HTML report rendering as a logo, a few empty
column headers and nothing else, with no error anywhere in the build log. Every
lab scenario producing HTML stopped at `HTML_BYTES > 1024`
(`scenarios/output-formats-coverage/verify.sh:158`) — file size, never rendering,
never served over HTTP. Nothing could have caught it.

More broadly, this is the third recipe defect the lab found by *running* the
documented chain rather than reading it. `java-ci-capture` covers the recipe on a
developer machine; this scenario covers it where CI actually differs: a clean
workspace, and an artifact served by the CI system's own web server.

## What it asserts

| id | assertion |
|----|-----------|
| J0 | the documented one-liner works on a **clean workspace**, as any CI job has |
| J1 | the job runs the recipe and `capture` writes a complete trace file |
| J2 | `analyze --ci` finds the planted `n_plus_one_sql` with the expected occurrences |
| J3 | `report.html` is produced and published by Jenkins |
| J4 | what the dashboard does when fetched **through Jenkins** under its default CSP — an observation, deliberately not a contract |
| J5 | with the remedy `docs/CI.md` prescribes, the dashboard renders |
| J7 | whether the fix `docs/CI.md:423` promises would actually help |
| J8 | the blocked page carries the `#ps-no-js` notice explaining why it is blank, and that notice is gone once the script runs |

J4 records rather than asserts, on purpose: today the dashboard is blank under
Jenkins' default CSP, and a gate that turned red when the product *improved*
would be a bad gate. If it ever renders, the leg passes with a loud note that the
limitation was lifted and the documentation needs revisiting.

J6 of the original design — option A of `docs/CI.md`, the Resource Root URL — is
**not covered**. It needs a second origin with its own hostname, and the CSP
behaviour is already established by J4 and J5. Stated here rather than silently
dropped.

## What it found (2026-08-01, released 0.9.24)

**J0 FAIL — the documented one-liner cannot work in CI.** The recipe is
`perf-sentinel capture --output target/traces.json -- mvn verify`
(`docs/INSTRUMENTATION.md:580`), and `docs/ci-templates/jenkinsfile.groovy:114`
sets `PERF_SENTINEL_TRACES` to that same path. A CI workspace starts clean, so
`target/` does not exist yet — Maven is what creates it, and Maven has not run.
`capture` correctly refuses to start when its output directory is missing:

```
Capture error: cannot write trace file target/traces.json: No such file or directory (os error 2)
```

The severity is in what follows: because `capture` refuses to start, **the
wrapped command never runs**. The integration suite does not execute, and the job
fails pointing at a trace file. Measured with the released binary inside the
controller, on a fresh directory: `rc=1`, wrapped command ran: `no`. No `mkdir`
appears anywhere in `docs/INSTRUMENTATION.md`, `docs/CI.md` or the four CI
templates.

`java-ci-capture` could not have caught this: it writes into a temporary
directory that already exists.

**J4 — the reported symptom, reproduced in situ.** Jenkins serves build artifacts
through `DirectoryBrowserSupport` under, measured on the response rather than
assumed:

```
sandbox allow-same-origin; default-src 'none'; img-src 'self'; style-src 'self';
```

Under it the dashboard is `BLANK rows=7/7 tabs=1/1` — exactly the static file,
no row and no tab built. The report packs its CSS and its ~4500 lines of
JavaScript inline and builds its entire content at load time; its own permissive
`<meta>` CSP cannot help, because a `<meta>` CSP and a header CSP **intersect**,
strictest wins. This is a documented limitation
(`docs/CI.md:374-425`), not a regression.

**J5 PASS — the documented remedy works.** Applying option B through the Script
Console, exactly as prescribed, gives `RENDERED rows=24/7 tabs=4/1`.

**J7 PASS — but the promised future fix would not help.** `docs/CI.md:423` says a
future release may split CSS and JavaScript into sibling files so the report
works on the default Jenkins CSP. Measured against the CSP Jenkins actually
served, with a control page carrying `<link href=r.css>` and `<script src=r.js>`:
the external script is **blocked too**. That CSP declares no `script-src`, so it
falls back to `default-src 'none'`, which covers external and inline alike.
Splitting the files would change nothing.

Per the lab's standing rule, these are reported, not fixed here.

## What it found (2026-08-02, pre-release 0.9.25)

8/8. Every observation above was acted on upstream, and this run measures the
result rather than taking the changelog's word for it.

**J0 PASS.** `capture` creates the output directory instead of refusing to start.
The one-liner runs on a clean workspace, the suite executes, 16 spans are
captured. `java-ci-capture` gained F7 and F8 for the same fix on the
developer-machine path.

**J7 still passes, and `docs/CI.md:423` no longer makes the promise it refuted.**
The measurement is kept: it is now the evidence behind a documented statement
rather than a contradiction of one.

**J8, new.** The report opens with a plain unstyled notice naming both causes of
a blank page — JavaScript off in the browser, or a policy sent by the server —
and a script immediately after it removes the notice while the page parses. So
the notice must be *present* exactly when the page failed to render and *absent*
when it rendered, which is what J8 asserts from J4's and J5's own DOM dumps. It
is not a rendered dashboard on a locked-down server, which no shape of this file
can be. It is the difference between a user seeing an explanation and a user
seeing nothing — the exact trip through the build logs that started this
scenario.

The CSP behaviour itself is unchanged, and should be: `BLANK rows=7/7 tabs=2/2`
under Jenkins' default policy, `RENDERED rows=24/7 tabs=5/2` with option B
applied.

## How it works

- A real controller built from `jenkins/jenkins:2.568.1-lts-jdk25` — the current
  LTS line, arm64-native. The perf-sentinel binary is taken from a perf-sentinel
  **image**, which is both the artifact a user installs and the only way to get a
  Linux binary from a macOS host. `PERF_SENTINEL_IMAGE` overrides which one: it
  defaults to the last published release, and a pre-release validation points it
  at a locally built tag. The default has to stay a real published tag, or a
  fresh clone builds nothing.
- Builds run on the controller. What is under test is the recipe and how Jenkins
  *serves* the result, not Jenkins' build topology.
- The pipeline is the upstream `jenkinsfile.groovy` shape with the HTML stages
  **uncommented** — they ship commented out, so this is the documented opt-in
  path. It keeps to trivial Groovy: a seeded job runs in the sandbox with no
  human to approve a script, and anything fancier fails before reaching the
  recipe.
- Jenkins enforces CSRF on POSTs, and the crumb is bound to the HTTP session, so
  every write shares one cookie jar. A crumb fetched with one curl and used by
  another is a 403.
- The Maven project is `scenarios/java-ci-capture/fixtures/`, already validated:
  one request, 15 single-row `SELECT`s, one `n_plus_one_sql` at 15 occurrences.
- Rendering goes through `scenarios/ci-e2e-common/render-check.sh` in URL mode,
  so the page is fetched from Jenkins itself and carries Jenkins' own headers.

## Run

```sh
make verify-ci-e2e-jenkins
```

Self-contained, no cluster. Needs Docker, curl, python3 and Chrome or Chromium.
Port 18080 must be free. The first run builds the image and resolves Maven from
scratch — allow around ten minutes. Report at
`/tmp/scenario-ci-e2e-jenkins-report.md`.
