# hub-plugin-contract

The payload the IDE plugin actually parses, captured from a running Hub.

## Why it exists

The plugin's parser is exercised only against JSON written in the plugin
repository, which proves the parser agrees with itself. The Hub's serializer is
exercised only against the Hub's own tests. Neither has ever seen the other.
Every field the plugin marks required is a field the Hub is free to rename, and
nothing in either CI would notice: `parseFindings` drops a malformed row rather
than the batch, so a rename empties the tool window **silently** instead of
raising.

## How the capture works

The scenario issues exactly the URI `findingsUri()` builds
(`?service=…&limit=1000&include_acked=true`, hardcoded here so a change on
either side shows up as a diff), asserts the payload carries everything
`parseFinding` marks required, and writes the raw response into the plugin
repository at:

```
src/test/resources/hub-contract/lab-order-service.json
```

Verifying is read-only. The capture always lands in
`/tmp/hub-plugin-contract/`, and installing it over the plugin's committed
fixture takes `HUB_CONTRACT_INSTALL_FIXTURE=yes`:

```bash
HUB_CONTRACT_INSTALL_FIXTURE=yes make verify-hub-plugin-contract
```

That separation matters because this scenario runs inside
`make verify-all-scenarios`: attesting a release must not leave another
repository dirty under an operator who never asked for a refresh. Refreshing
stays a deliberate act, run it, review the diff, commit it. The capture is
pretty-printed with sorted keys so the diff is readable.

Point the plugin checkout elsewhere with `PERF_SENTINEL_PLUGIN_REPO_PATH`.

## The other half, in the plugin repository

`HubContractTest` replays the fixture through the real `DaemonClient` over a
loopback `HttpServer`, on the `withServer` harness `DaemonClientTest` already
uses. Two assertions: every captured finding parses (counted, since a dropped
row is silent), and the five Hub-owned keys the daemon never sent are ignored
rather than tripped on.

```bash
./gradlew :test --tests '*HubContractTest*'
```

## The gap this scenario measures rather than hides

**No finding in this lab carries a `code_location`.** The OpenTelemetry Java
agent attaches no `code.*` attributes to JDBC spans, so the anchor the plugin
navigates on is absent from every JVM-instrumented service here. The parse
contract is real; the navigation contract is not covered by this capture, and
stays owned by the plugin's own anchor resolver tests.

Sub-test 4 counts anchored findings rather than requiring zero: if the
instrumentation ever starts emitting them, the count rises and the navigation
contract becomes testable from a real capture. A fixture with a fabricated
anchor would have proven nothing about the daemon's path conventions.

## Running it

```bash
make verify-hub-plugin-contract
```

Needs the cluster, `make seed-services`, `make seed-hub-local` and
`make port-forward`.
