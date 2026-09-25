# micrometer-http-client

A Spring Boot 4 service traced through Micrometer Observation, never through
the OTel Java agent, read by perf-sentinel over every ingest format it can
reach: OTLP, Zipkin v2 JSON, Jaeger JSON and the daemon's OTLP receiver.

## Why it exists

Micrometer tags the spans of RestClient, RestTemplate and WebClient with its
own names, `method` and `status`, where OTel writes `http.request.method` and
`http.response.status_code`. That holds for both bridges a Spring Boot service
picks from: `spring-boot-starter-opentelemetry` (OTLP) and the Brave bridge of
`spring-boot-starter-zipkin`. Up to 0.25.1 perf-sentinel knew only the OTel
names, so every such call read as a `GET` without a status, and a `POST` and a
`GET` to the same URL fused into one `n_plus_one_http` finding. 0.25.2 reads
the two Micrometer tags after both OTel conventions, and only on a span it
already classified as an outbound call through its URL.

Every Java service in the lab runs the OTel agent, so none of them emits this
shape. The unit tests upstream build it by hand, and this scenario is where it
comes from the emitter itself.

## What it asserts

| id | assertion |
|----|-----------|
| B0 | both fixture profiles build (`otlp`, `zipkin`) |
| O1 | the OTLP capture holds 14 CLIENT spans shaped by Micrometer alone: `method` and `status` present, no OTel HTTP method or status key |
| O2 | `analyze` splits `n_plus_one_http` into `POST localhost/api/items/{id}` x6 and `GET localhost/api/items/{id}` x7 |
| O3 | the events embedded in the HTML report: `POST` 201 x6, `GET` 200 x6, `GET` 404 x1, and the call that got no response (`status=CLIENT_ERROR`) carries no status |
| Z1-Z3 | the same three on the Zipkin v2 JSON the Brave bridge posts |
| J1-J3 | the same three on the Jaeger JSON of the OTLP capture replayed into a throwaway Jaeger |
| D1 | the daemon, fed by the app directly over OTLP HTTP, reports the same two findings |
| P1 | each finding keeps one signature across the four paths |

O1, Z1 and J1 guard the premise. Should a Spring release switch its default
convention to the OTel names, they fail rather than let the rest pass on a
path that no longer reaches the Micrometer tags.

Run against 0.25.1 the scenario fails the eight method and status checks
(every path reads `GET localhost/api/items/{id}` x13 without a status), and B0,
O1, Z1 and J1 pass on both.

## The fixture

`fixtures/` is one Spring Boot 4.1.1 application. On startup it calls its own
`GET /batch` once through the JDK client, which is not observed, so the trace
root is that inbound span. `/batch` then fans out through the auto-configured
`RestClient`: 6 `POST` and 6 `GET` to `/api/items/{id}`, one `GET` answered
404, and one call to port 1, refused, which Micrometer closes with
`status=CLIENT_ERROR` and `outcome=UNKNOWN`. The app then exits, which flushes
the exporter. 28 spans in all: 14 SERVER spans, the `/batch` root among them,
and 14 CLIENT spans.

The Maven profile picks the bridge: `otlp` (default) adds
`spring-boot-starter-opentelemetry`, `zipkin` adds `spring-boot-starter-zipkin`.
`zipkin-sink.py` is a minimal Zipkin collector that stores what it receives,
and `census.py` holds the parsers the assertions share.

## Run

```bash
cargo build --release   # in the perf-sentinel checkout
make verify-micrometer-http-client
```

Needs the local release binary, JDK 25, Maven, python3 and Docker (Jaeger
only). No cluster. Around a minute once Maven has its dependencies.

`PERF_SENTINEL_LOCAL_BIN` points at another binary, which is how the 0.25.1
control above runs. `JAEGER_IMAGE` overrides the Jaeger image.

## Watch out

**Jaeger 2.21.0 has no `/api/traces`.** It removed the v1 HTTP endpoints the
UI no longer calls (jaegertracing/jaeger#9260), and Jaeger JSON is what that
API returns. The scenario pins 2.20.0. The same removal breaks
`perf-sentinel jaeger-query` against Jaeger 2.21.0 and later.

**The SERVER spans carry `method` and `status` too.** Micrometer tags the
inbound side with the same keys and an `http.url` holding the path. They stay
out of the outbound events because perf-sentinel never turns a SERVER span
into an outbound call, which is what keeps the counts at 14.
