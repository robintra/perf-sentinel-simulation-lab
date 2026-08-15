# ci-e2e-github

The documented Java CI recipe run through a **real GitHub Actions workflow**,
executed locally by `act`, from the Maven integration test to whether the
published dashboard renders in a browser.

## Why it exists, and what it does not cover

On GitHub the display risk that motivated this family is **low by construction**,
and saying so matters more than pretending otherwise:

- job artifacts are zip downloads that GitHub never renders in a browser;
- GitHub Pages serves HTML without a restrictive Content-Security-Policy.

The CSP failure lives in Jenkins, which serves build artifacts through
`DirectoryBrowserSupport` under a policy that blanks the dashboard. See
`scenarios/ci-e2e-jenkins/`. What this scenario buys is the **chain**: a real
workflow engine really running the recipe, `capture` really writing the file,
and what lands on Pages really rendering. H4 measures that rather than
assuming it, which is the whole point of the family.

## What it asserts

| id | assertion |
|----|-----------|
| H1 | `act` runs the workflow to completion, HTML steps included |
| H2 | `capture` wrote a complete trace file and `analyze` finds the planted N+1 |
| H3 | `report.html` is produced and lands where the workflow publishes it |
| H4 | served the way GitHub Pages serves it, the dashboard renders |

## What it found (2026-08-01, released 0.9.24)

**4/4 PASS**: 16 spans (15 JDBC + 1 SERVER), `n_plus_one_sql` at 15
occurrences, a 467 KB dashboard, and `RENDERED rows=24/7 tabs=4/1` when
served without a restrictive CSP, the same report that comes out blank
through Jenkins.

Building it surfaced one defect that belongs to the recipe rather than to act,
already reported as J0 by `ci-e2e-jenkins`: `capture --output target/traces.json`
cannot run on a clean CI workspace, because `target/` does not exist until Maven
creates it. The workflow carries an explicit `mkdir -p target` with that reason
written next to it.

It also surfaced a **fixture** defect worth recording, because it is exactly the
developer-machine versus CI-runner gap these scenarios exist to catch: the Maven
project relied on `maven.compiler.release` without pinning
`maven-compiler-plugin`. Which plugin version Maven binds depends on the Maven
the runner ships, and an old one ignores `release` and silently falls back to
source/target 5. It passed on a developer machine and failed in the runner. The
plugin is now pinned in `scenarios/java-ci-capture/fixtures/pom.xml`, which all
three scenarios share.

## How it works

- The repository act runs against is assembled in `/tmp`: the workflow, the
  Maven project copied from `scenarios/java-ci-capture/fixtures/` (one
  project, one place to change it), and the perf-sentinel binary extracted
  from the **released** image, which `PERF_SENTINEL_IMAGE` overrides for a
  pre-release round. The default has to stay a real published tag.
- `act --bind` mounts the working directory instead of copying it into the
  runner. Without it act's copy stays inside the container and the workflow's
  outputs never reach the host, so the assertions would have nothing to read.

Four departures from the published template, all about running under act rather
than about the recipe, and all commented in `fixtures/workflow.yml`:

- the binary comes from the workspace instead of GitHub Releases: the release
  asset is linux/amd64 and the runner here is arm64, and the download is not
  what is under test;
- the SARIF upload and the PR comment are dropped, both needing the GitHub API;
- PostgreSQL runs on a named docker network rather than through a `services:`
  block, because act does not give the runner container the service's hostname
  alias;
- Java and Maven are set up in steps, because GitHub-hosted runners ship both and
  act's `catthehacker` image ships neither a JDK recent enough for `release 17`
  nor Maven at all. `actions/setup-java` is what a real workflow uses anyway, and
  it pins `JAVA_HOME` so Maven cannot fall back to whatever `javac` the image
  happens to carry.

The HTML steps are **uncommented** relative to
`docs/ci-templates/github-actions.yml`, where they ship commented out: that is
the documented opt-in path, and the one worth exercising.

## Run

```sh
make verify-ci-e2e-github
```

Self-contained, no cluster. Needs Docker, `act` (`brew install act`), python3
and Chrome or Chromium. The first run pulls the runner image and resolves
Maven from scratch. Allow around ten minutes. Report at
`/tmp/scenario-ci-e2e-github-report.md`.
