# java-ci-capture

Runs the upstream Java CI recipe end to end — `docs/INSTRUMENTATION.md`, section
*CI integration tests (Maven Failsafe)*, Option 1, `perf-sentinel capture` — and
holds the exit-code contract that command promises.

> **Quarantined: this scenario currently FAILs on 3 of its 12 assertions.**
> It is deliberately **not** part of `make verify-all-scenarios` and not counted
> in the 60 release-gate scenarios, so the gate keeps reporting on everything
> else. Wire it in (`.PHONY`, the `verify-all-scenarios` loop, the count in
> `docs/SCENARIOS.md` and the Makefile help) once it goes green. See
> *What it found*, below.

## Why it exists

The recipe for producing a trace file from a Java CI job has been wrong twice.
First it named `OTEL_TRACES_EXPORTER=otlp_file` with
`OTEL_EXPORTER_OTLP_FILE_PATH`, two names that exist nowhere in OpenTelemetry; an
external user followed it on a Jenkins + Maven pipeline and got no traces at all.
Then it moved to `experimental-otlp/stdout`, which a forked Failsafe cannot hand
back: Surefire talks to its fork over an encoded channel carried on that fork's
stdout, and the agent captures that stream in `premain`, before Surefire installs
the wrapper `redirectTestOutputToFile` acts on. This scenario is what measured
that, across Failsafe 3.5.0, 3.2.5 and 2.22.2.

`capture` receives OTLP over the network instead, so the fork stays untouched.
Every lab batch scenario before this one obtained its trace file from committed
fixtures, a Collector `file` exporter, or a backend query API — never from a
language agent. That gap is why both broken recipes shipped.

## What it asserts

| id | assertion |
|----|-----------|
| D0 | the POM **exactly as published** produces a non-empty capture |
| D1 | `mvn verify` runs normally, fork included, with no `Corrupted channel` and no `.dumpstream` |
| D2 | Maven's own logs reach the console untouched and perf-sentinel writes nothing to stdout |
| D3 | `analyze --ci` on the captured file finds `n_plus_one_sql` with the **same census** as the same run exported to a Collector `file` exporter |
| D4 | a failing test surfaces as Maven's own non-zero exit code through the wrapper |
| D5 | the service form (`capture &`, then `kill -TERM`) yields the same counters as the wrapped form |
| D6 | the last export batch is not lost: the file carries every span |
| F1 | `--max-file-size` exceeded: exit 2, a message naming the flag, file still valid |
| F2 | a request refused **before** the queue is not reported as backpressure |
| F3 | `--output` in a missing directory: exit 1, and the wrapped command never runs |
| F4 | SIGTERM during a wrapped capture: child stopped, no orphan left, file still valid NDJSON |
| F5 | `--listen-address 0.0.0.0` reached from a neighbouring container |

D3's Collector run doubles as the control: if it finds nothing either, the
fixture is at fault rather than the capture, and the scenario says so instead of
blaming the recipe. F1 SKIPs rather than fails when the generator cannot push
1 MiB within `F1_WAIT_S` — a slow host must not read as a broken size guard.

## What it found (2026-07-30, product `feature/0.9.24` @ `9c186516`)

`capture` itself works: D1–D6 all pass, and the captured file is finding-for-
finding identical to a Collector export of the same run, 15 occurrences for 15
queries. Three assertions fail.

**D0 — the published POM captures nothing.** The recipe sets
`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` and says nothing about the
protocol, on the assumption that the Java agent defaults to gRPC. Agent 2.27.0
defaults to `http/protobuf`, and says so itself:

```
OTLP exporter endpoint port is likely incorrect for protocol version
"http/protobuf". The endpoint http://localhost:4317 has port 4317.
Typically, the "http/protobuf" version of OTLP uses port 4318.
```

The exporter then posts HTTP to capture's gRPC port, nothing arrives, and the
file is empty. Measured: endpoint on `:4318` captures 16 spans; `:4317` plus an
explicit `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` captures 16 spans; the published
combination captures 0. This is not a silent false green — `analyze` rejects the
empty file with `trace file is empty: nothing was captured or exported` — but the
job fails on a confusing cause rather than on its own tests.

**F2 — a refused request is reported as backpressure.** Any request that reaches
`/v1/traces` and is refused before ingest is counted in the same statistic that
backs exit 2. A single `Content-Type: application/json` POST (415) is enough:

```
Capture: 1 requests could not be queued and were refused, <file> is incomplete.
The exporter was faster than the writer.          →  exit 2
```

Nothing was ever queued, so the diagnosis is wrong, and it points the user at
queue sizes when the actual problem is a misconfigured exporter — the same family
as D0, and the shape produced by `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`, which
several SDKs accept. A malformed protobuf body (400) is counted the same way. An
unrouted request (`GET /`, 404) is correctly ignored, so the scope is requests
landing on the traces endpoint. Side effect: genuine backpressure cannot be
distinguished from a protocol mismatch through this counter, which is why the
"exporter faster than the writer" burst is not separately exercised here.

**F4 — SIGTERM leaves an orphaned grandchild.** The file is flushed cleanly and
stays valid NDJSON, and the direct child is stopped, so the wrapped command does
not complete. But only the direct child is signalled: with
`capture -- sh -c "sleep 90; ..."`, the `sh` dies and the `sleep` survives,
reparented to PID 1. In a real job, `capture -- mvn verify` cancelled mid-run
leaves the Failsafe **fork** — a JVM holding a port and a database connection —
behind. Signalling the process group rather than the child would close it.

Per the validation handoff, the lab reports the observed behaviour and does not
edit the upstream documentation.

## How it works

- `fixtures/pom.xml` copies the `maven-dependency-plugin` and
  `maven-failsafe-plugin` blocks **verbatim** from the docs. The one indirection
  is the OTLP endpoint, a property whose **default is the documented literal**, so
  D0 exercises the published configuration and the later legs can override it.
  `OTEL_EXPORTER_OTLP_PROTOCOL` is deliberately absent from the POM: the recipe
  omits it, and declaring it empty is not the same thing — an empty value aborts
  autoconfiguration outright. Legs that need it export it into the environment,
  which the Failsafe fork inherits.
- `fixtures/.../OrderItemsIT.java` is the integration test a CI pipeline would
  run: one request, 15 single-row `SELECT`s against a throwaway PostgreSQL. The
  SERVER span is opened by hand because the project has no web framework for the
  agent to instrument; the JDBC spans are the agent's own. `LAB_FAIL` makes it
  fail on purpose for D4, after the spans have been exported.
- The statement sanitizer is disabled, the one departure from the documented
  environment that concerns the payload rather than the capture: its default
  rewrites every literal to `?`, collapsing the N+1 into a redundant-query
  finding.
- The F legs use `telemetrygen` from a neighbouring container, which is also what
  makes F5 a real cross-container test rather than a loopback one.
- The project is copied into `/tmp` before building, so no `target/` ever appears
  in the repository.

## Run

```sh
make verify-java-ci-capture
```

Self-contained, no cluster. Needs the local release binary (`cargo build
--release -p perf-sentinel`), a JDK, Maven, and Docker. Ports 4317/4318 must be
free — the documented endpoint targets them. Report at
`/tmp/scenario-java-ci-capture-report.md`.
