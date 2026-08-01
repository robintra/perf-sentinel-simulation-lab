# ci-e2e-gitlab

The documented Java CI recipe run by a **real GitLab pipeline** on the lab's
Kubernetes runner, from the Maven integration test to the dashboard served by
**GitLab Pages over HTTP**.

## Why it exists

This is the only member of the `ci-e2e-*` family with a genuine CI engine already
in the lab: `make up-gitlab` deploys GitLab CE with a Kubernetes-executor runner
that runs real pipelines and real merge requests.

It also closes a gap the lab had documented against itself.
`docs/GITLAB-CI.md:83-86` noted that the Pages job produces `public/index.html`
but that `${CI_PAGES_URL}` is never fetched over HTTP. G4 fetches it, loads it in
a browser, and asserts the dashboard actually rendered — which is the whole point
of this family, and something no lab scenario did before.

## What it asserts

| id | assertion |
|----|-----------|
| G1 | the pipeline runs on the runner and `capture` writes a complete trace file |
| G2 | `analyze` finds the planted `n_plus_one_sql` with the expected occurrences |
| G3 | the Pages job publishes `public/index.html` |
| G4 | fetched from GitLab Pages **over HTTP**, the dashboard renders |

## What it found (2026-08-01, released 0.9.24)

The chain works: the pipeline succeeds, the runner captures 16 spans (15 JDBC +
1 SERVER), `analyze` reports `n_plus_one_sql` at 15 occurrences, and a 467 KB
dashboard reaches Pages and renders. Like GitHub and unlike Jenkins, GitLab Pages
serves without a restrictive Content-Security-Policy, so the same report that
comes out blank through Jenkins is fully interactive here.

It also confirmed, from a third angle, the defect `ci-e2e-jenkins` reports as J0:
`capture --output target/traces.json` cannot run on a clean CI workspace, since
`target/` does not exist until Maven creates it. The pipeline carries an explicit
`mkdir -p target` with that reason written beside it.

## Infrastructure this scenario required

Two lab-side changes, both deliberate and both worth knowing about.

**Egress for CI job pods.** The GitLab Kubernetes executor creates a fresh pod per
job, and those pods carry none of the labels `gitlab-runner-egress` selects on, so
they fell through to `default-deny-all` and could reach nothing — not a package
mirror, not Maven Central. Any real Java pipeline in this cluster failed at
dependency resolution. `manifests/network-policies.yaml` now carries
`gitlab-ci-jobs-maven-egress`: namespace-wide on the source because job pods are
unlabelled, but opening **only** Maven Central over 443. Nothing else in
`gitlab-ce` gains egress it did not have.

**The integration test seeds its own schema.** It used to rely on a `psql` step,
which needs a package mirror the runner cannot reach. `OrderItemsIT` now creates
and fills its table itself, idempotently, before the request span opens. One
fixture, no external seeding, and all three `ci-e2e-*` scenarios benefit.

Note the ordering constraint in that fixture: the setup statements run **before**
the SERVER span and on their own connection. The agent instruments them anyway —
they simply land in their own single-span traces — which is why the scenarios
count the spans of the **largest trace** rather than every span in the file.
Counting the file would report 18 instead of 16 and turn a correct capture into a
false failure.

## How it works

- The scenario clones the project seeded by `make seed-gitlab-project`, drops in
  the pipeline, the Maven project copied from
  `scenarios/java-ci-capture/fixtures/`, and the perf-sentinel binary extracted
  from the **released** image, then pushes and waits for the pipeline.
- The commit is made with `--allow-empty` on purpose: a re-run with unchanged
  fixtures must still trigger a pipeline, or the scenario would silently report
  the previous run's verdict.
- The binary is committed into the project rather than downloaded from GitHub
  Releases: the runner then needs no egress to github.com, and the arm64 lab gets
  an arm64 binary instead of the amd64 release asset.
- G4 port-forwards **port 9090 on the Pages pod**, not 8090 on the service: 8090
  is the PROXY listener and expects PROXY-protocol headers, 9090 is plain HTTP.
  GitLab serves each project on a unique domain
  (`<project>-<hash>.pages.localhost`) and 308-redirects the namespace URL to it,
  so the readiness probe follows redirects and Chrome does the same natively.
  `*.localhost` resolves to 127.0.0.1, so the forwarded port survives the hop and
  no `/etc/hosts` surgery is needed.

The integration-test and Pages jobs are **uncommented** relative to
`docs/ci-templates/gitlab-ci.yml`, where they ship commented out: that is the
documented opt-in path, and the one worth exercising.

## Run

```sh
make up-gitlab && make seed-gitlab-project   # ~10 min, once per cluster
make verify-ci-e2e-gitlab
```

Needs the cluster, GitLab CE, python3 and Chrome or Chromium. SKIPs cleanly when
GitLab is not up. The pipeline resolves Maven from scratch on each run — allow
around ten minutes. Report at `/tmp/scenario-ci-e2e-gitlab-report.md`.
