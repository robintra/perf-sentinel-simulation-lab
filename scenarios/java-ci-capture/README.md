# java-ci-capture

Runs the upstream Java CI recipe end to end (`docs/INSTRUMENTATION.md`,
section *CI integration tests (Maven Failsafe)*, Option 1,
`perf-sentinel capture`) and holds the exit-code contract that command
promises.

## Why it exists

The recipe for producing a trace file from a Java CI job shipped broken,
twice, and was still broken on its first rewrite. It first named
`OTEL_TRACES_EXPORTER=otlp_file` with `OTEL_EXPORTER_OTLP_FILE_PATH`, two
names that exist nowhere in OpenTelemetry. An external user followed it on a
Jenkins + Maven pipeline and got no traces at all. The *History* table below
traces what happened next.

The reason none of it was caught is structural: every lab batch scenario
before this one obtained its trace file from committed fixtures, a Collector
`file` exporter, or a backend query API, never from a language agent. Every
scenario started one step downstream of the thing the documentation described.

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
| F2 | a request refused **before** the queue is named unusable and points at `OTEL_EXPORTER_OTLP_PROTOCOL`, never at the writer |
| F3 | `--output` under a parent that is a **regular file**: exit 1, and the wrapped command never runs |
| F4 | SIGTERM during a wrapped capture: child stopped, no orphan left, file still valid NDJSON |
| F5 | `--listen-address 0.0.0.0` reached from a neighbouring container |
| F6 | genuine writer saturation is reported as backpressure, and **only** as that |
| F7 | `--output target/traces.json` on a **clean workspace**: the directory is created and the suite runs |
| F8 | the wrapped command deleting `target/` mid-capture **fails** the run instead of reporting a span count |

D3's Collector run doubles as the control: if it finds nothing either, the
fixture is at fault rather than the capture, and the scenario says so instead
of blaming the recipe. F1 SKIPs rather than fails when the generator cannot
push 1 MiB within `F1_WAIT_S`, and F6 likewise when the generators never fill
the 256-slot channel within `F6_BLOCK_S`. A slow host must not read as a
broken size guard or a broken backpressure counter.

## History

The recipe took three rounds to become runnable, and each failure was found by
running it rather than by reading it.

| round | product | outcome |
|---|---|---|
| 1 | `8839da06` | `experimental-otlp/stdout`: a forked Failsafe cannot hand back its stdout; the agent captures the fork's command channel in `premain`, so every export was diverted into a `.dumpstream`. Measured identically on Failsafe 3.5.0, 3.2.5 and 2.22.2, and on the documented `tee` fallback. |
| 2 | `9c186516` | `capture` introduced and sound, but three defects: the published POM pointed `:4317` while agent 2.x defaults to `http/protobuf` (0 spans captured); a request refused *before* the queue was reported as writer backpressure; SIGTERM killed only the direct child, orphaning the grandchild to PID 1. |
| 3 | `57d2a2f9` | all three fixed. The POM states the protocol, the two rejection causes have separate counters and messages, and the wrapped command runs in its own process group. **13/13 PASS.** |
| 4 | `0.9.25` | the defect `ci-e2e-jenkins` reported as J0 is fixed: `capture` creates the output directory instead of refusing to start. F3 moves to a refusal a `mkdir` cannot fix, F7 and F8 are new. **15/15 PASS.** |

Round 3 also made F6 possible: while protocol rejections and queue rejections
shared one counter, a saturation measurement could not mean anything. With them
separated, the leg below is interpretable, and it passes.

Round 4 is the one this scenario did **not** find. F3 passed here for the wrong
reason: it wrote into a directory that already existed, which is a developer
machine, not a CI workspace. A real Jenkins controller with a fresh workspace is
what surfaced it, which is why the three `ci-e2e-*` scenarios exist.

Note what F7 and F8 together say about the shape of the command. Since the trace
file lives under `target/`, `capture --output target/traces.json -- mvn clean
verify` **cannot succeed**: `clean` unlinks the file capture is writing to, and
F8 asserts that this is now reported rather than hidden. The documented recipe
uses `mvn verify` for exactly that reason. A pipeline that wants `clean` must put
the trace file outside the directory being cleaned.

## How it works

- `fixtures/pom.xml` copies the `maven-dependency-plugin` and
  `maven-failsafe-plugin` blocks **verbatim** from the docs. The one indirection
  is that the OTLP endpoint and protocol are properties whose **defaults are the
  documented literals**, so D0 exercises the published configuration untouched
  and the Collector reference leg can point elsewhere. Do not turn either into an
  empty default: an empty `OTEL_EXPORTER_OTLP_PROTOCOL` aborts autoconfiguration
  outright, which is a third, differently-broken state.
- `fixtures/.../OrderItemsIT.java` is the integration test a CI pipeline would
  run: one request, 15 single-row `SELECT`s against a throwaway PostgreSQL.
  The SERVER span is opened by hand because the project has no web framework
  for the agent to instrument. The JDBC spans are the agent's own. `LAB_FAIL`
  makes it fail on purpose for D4, after the spans have been exported.
- The statement sanitizer is disabled: the one departure from the documented
  environment that concerns the payload rather than the capture, and it is
  about **determinism, not correctness**. Measured: with the sanitizer on, the
  default `auto` mode still reports `n_plus_one_sql` through its recovery
  heuristic. But this project is plain JDBC with no ORM scope marker, so that
  heuristic rests on timing variance alone, and at 10 occurrences instead of
  15 `strict` already falls back to `redundant_sql`. A gate assertion must not
  depend on how loaded the machine was. This is **not** advice to disable the
  sanitizer in a real pipeline: doing so writes raw SQL literals into a trace
  file that CI commonly publishes as a job artifact, and `auto` does not need
  it.
- The F legs use `telemetrygen` from a neighbouring container, which is also what
  makes F5 a real cross-container test rather than a loopback one.
- F6 cannot make the exporter fast enough, because a container reaches roughly
  one request per second through the host bridge. It slows the writer instead.
  The output is a FIFO whose reader holds it open and reads nothing, which
  stalls the writer while the 256-slot channel fills, then drains so capture
  can exit. The rejection counts are a summary printed at exit, not a stream,
  so the leg waits out the block rather than polling for a message that cannot
  appear yet.
- The project is copied into `/tmp` before building, so no `target/` ever appears
  in the repository.

## Run

```sh
make verify-java-ci-capture
```

Self-contained, no cluster. Needs the local release binary
(`cargo build --release -p perf-sentinel`), a JDK, Maven, and Docker. Ports
4317/4318 must be free, because the documented endpoint targets them. Report
at `/tmp/scenario-java-ci-capture-report.md`.
