# java-stdout-exporter

Runs the upstream Java CI recipe end to end — the one from
`docs/INSTRUMENTATION.md`, section *CI integration tests (Maven Failsafe, stdout
exporter)*.

> **Quarantined: this scenario currently FAILs, and that is the finding.**
> It is deliberately **not** part of `make verify-all-scenarios` and not counted
> in the 60 release-gate scenarios, so the gate keeps reporting on everything
> else. Wire it in (`.PHONY`, the `verify-all-scenarios` loop, the count in
> `docs/SCENARIOS.md` and the Makefile help) once the upstream recipe is fixed
> and this goes green. See *What it found*, below.

## Why it exists

Java has no OTLP file exporter. Until product 0.9.24 the documented recipe named
`OTEL_TRACES_EXPORTER=otlp_file` with `OTEL_EXPORTER_OTLP_FILE_PATH`, two names
that exist nowhere in OpenTelemetry. An external user followed it on a Jenkins +
Maven pipeline, got no traces at all, and ended up deploying a collector just to
obtain a file. Nothing in the lab executed that recipe, so nothing caught it —
the same blind spot the three `template-*` scenarios close for the CI templates.

## What it asserts

| id | assertion |
|----|-----------|
| B1 | the agent autoconfigures on `experimental-otlp/stdout`: no `Unrecognized value`, and the exporter actually emits OTLP batches (counted wherever they land, so agent health stays separable from output routing) |
| B2 | every emitted batch is reachable by the documented `grep -h '^{"resourceSpans"'` — nothing lost to a logger prefix or to a Surefire stream diversion |
| B3 | `redirectTestOutputToFile` parks those batches in `target/failsafe-reports/<Class>-output.txt`, where the documented glob reads |
| B4 | `analyze --ci` on the captured file yields the planted `n_plus_one_sql`, with a census identical to the **same test** exported over the network to a collector file exporter |
| B5 | `OTEL_TRACES_SAMPLER=always_on` keeps every repetition: N queries produce N occurrences |

B4's network run is also the control. If it finds nothing either, the fixture is
at fault rather than the capture, and the scenario dies with that message instead
of blaming the recipe.

## What it found (2026-07-30, product `feature/0.9.24` @ `8839da06`)

**B1 PASS, B2/B3/B4/B5 FAIL.** The agent is fine — it emits a complete trace, a
SERVER span with 15 distinct JDBC children. The traces never reach the file:

```
Corrupted channel by directly writing to native stream in forked JVM 1.
Stream '{"resourceSpans":[...]}'
```

Surefire and Failsafe talk to their forked JVM over an encoded channel on the
fork's stdout. The OTel agent initialises in `premain`, so it captures the
*original* `System.out` — the channel itself — before Surefire installs the
wrapper that `redirectTestOutputToFile` acts on. The agent's writes therefore
bypass the redirect entirely, Surefire flags them as channel corruption, and
parks them in `target/failsafe-reports/<timestamp>-jvmRunN.dumpstream`, wrapped
in that message. No line starts with `{"resourceSpans"` any more, so the
documented grep returns nothing and `analyze` gets an empty file.

Verified, so the diagnosis is not guesswork:

- **Not a version regression.** Failsafe 3.5.0, 3.2.5 and 2.22.2 all divert it
  (2.22.2 words it `Corrupted STDOUT by directly writing to native stream`).
  Zero capturable lines in all three.
- **The documented fallback fails too.** `set -o pipefail && mvn verify | tee
  build.log` then grepping `build.log` yields zero lines: the fork's stdout is
  the channel, not the console.
- **The redirect mechanism itself works.** A plain `System.out.println` from the
  test lands in `-output.txt` and matches the grep. Only the agent's writes are
  diverted, which is what pins the cause on the premain-captured stream.
- **One configuration does work**: `<forkCount>0</forkCount>` (no fork, no
  channel), the agent attached through `MAVEN_OPTS` and the `OTEL_*` settings
  passed as real environment variables, since `<argLine>` and
  `<environmentVariables>` only apply to forks. The full chain then produces
  `n_plus_one_sql` with 15 occurrences for 15 queries. Note this is the opposite
  of the direction the recipe took: it dropped a `<forkCount>1</forkCount>`
  constraint, where the working constraint is `forkCount=0`.

Per the validation handoff, the lab reports the observed behaviour and does not
edit the upstream documentation. When the recipe is corrected, update
`fixtures/pom.xml` to match it verbatim and re-run.

## How it works

- `fixtures/pom.xml` copies the `maven-dependency-plugin` and
  `maven-failsafe-plugin` blocks **verbatim** from `docs/INSTRUMENTATION.md`. If
  the recipe drifts, this file follows it, never the reverse — running something
  other than what the docs say would defeat the scenario.
- `fixtures/.../OrderItemsIT.java` is the integration test a CI pipeline would
  run: one request, 15 single-row `SELECT`s against a throwaway PostgreSQL. The
  SERVER span is opened by hand because the project has no web framework for the
  agent to instrument; the JDBC spans are the agent's own, and they are what the
  capture chain has to carry.
- Two departures from the documented environment, both about the payload rather
  than the capture, and both commented in the pom: the statement sanitizer is
  disabled (its default rewrites every literal to `?`, collapsing the N+1 into a
  redundant-query finding) and the OTLP endpoint is templated so the same test
  can be replayed over the network for B4.
- The project is copied into `/tmp` before building, so no `target/` ever appears
  in the repository.

## Run

```sh
make verify-java-stdout-exporter
```

Self-contained, no cluster. Needs the local release binary (`cargo build
--release -p perf-sentinel`), a JDK, Maven, and Docker (throwaway PostgreSQL,
plus a throwaway collector for the parity leg). Report at
`/tmp/scenario-java-stdout-exporter-report.md`.
