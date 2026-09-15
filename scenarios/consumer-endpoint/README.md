# consumer-endpoint (0.22.2 consumer destination as `source.endpoint`)

## Purpose

Since 0.22.2 a finding whose only same-service ancestor is a message
CONSUMER span names its destination, `<messaging.system> <destination>`,
instead of `"unknown"`. The rule ranks below an inbound route and below a
code frame, so it only names what would otherwise be anonymous. This
scenario locks that rule on the daemon path with a real consumer: the
batch twin is family F of `endpoint-resolution`.

The consumer has to live in another service than the publisher. The Java
agent injects the producer's context into the AMQP headers on
`basicPublish` (`rabbitmq-2.7`, `RabbitChannelInstrumentation`,
`ChannelPublishAdvice`) and the spring-rabbit CONSUMER span adopts it as
parent (`spring-rabbit-1.0`, `SpringRabbitSingletons`). Inside one
service the ancestor walk would climb through the PRODUCER span to the
publishing HTTP route, which wins by design. Across a service boundary
the walk stops at the CONSUMER span. notification-service therefore
consumes the `perfsim.order-service` queue and runs 12 reads per
message. The agent writes the received routing key to
`messaging.destination.name` (`SpringRabbitMessageAttributesGetter`,
`getDestination`), so the expected endpoint is `rabbitmq order-service`,
neither the queue nor the exchange.

## Prerequisites

- `make up-cni`
- `make seed-services` after the listener change (same `s2` tag, the
  new env values force the rollout)
- `make seed-daemon-local` with `PERF_SENTINEL_REV=feature/0.22.2` or
  a later branch
- `scripts/port-forward.sh start`

## Run

```bash
make verify-consumer-endpoint
```

The script sources `scripts/validate-findings.sh` for `run_scenario`
(the k6 Job template, the baseline trace-id snapshot, the
`stored_at_ms` freshness and the type + service + endpoint match), then
drives `scenarios/n-plus-one-messaging.js` and reads `/api/findings`.

## Assertions

| id | assertion                                                              | 0.22.2                    | 0.22.1 baseline      |
|----|------------------------------------------------------------------------|---------------------------|----------------------|
| C1 | a fresh `n_plus_one_sql` on notification-service names the destination | PASS                      | FAIL                 |
| C2 | every fresh consumer finding carries the same destination              | `['rabbitmq order-service']` | FAIL, `['unknown']` |
| C3 | each finding carries at least the 12 reads of one message              | PASS                      | same                 |
| C4 | the findings sit on several fresh traces                               | PASS                      | same                 |

C2 exercises the daemon work of the branch: consumer destinations are
retained across exports so the reads that flush before the CONSUMER span
ends get repaired. A mix of `unknown` and the destination is a product
finding to report, not a lab tolerance to add.

## A/B against 0.22.1

```bash
PERF_SENTINEL_REV=v0.22.1 make seed-daemon-local && make verify-consumer-endpoint   # expect C1 and C2 FAIL, endpoint "unknown"
PERF_SENTINEL_REV=feature/0.22.2 make seed-daemon-local && make verify-consumer-endpoint   # expect 4/4
```

About 10 minutes for both legs.

## Discovering the spelling

The report prints the endpoint histogram of the fresh findings. To read
the attribute itself:

```bash
kubectl -n observability port-forward svc/tempo 3200:3200
curl 'localhost:3200/api/search?q={resource.service.name="notification-service" && kind=consumer}'
curl localhost:3200/api/traces/<id>
```

and read `messaging.destination.name` on the CONSUMER span. Override
with `EXPECTED_ENDPOINT=...` only after updating this README with the
source that justifies it.

## Output

`/tmp/scenario-consumer-endpoint-report.md` plus the raw findings at
`/tmp/consumer-endpoint-findings.json`.

## Related

`endpoint-resolution` family F is the batch twin (fixtures F1 to F14,
no cluster).
