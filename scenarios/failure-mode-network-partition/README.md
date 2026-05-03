# failure-mode-network-partition

Validate the daemon survives a network partition that severs incoming
OTLP traffic. The daemon's pod stays up but its ingress is fully
denied for `PARTITION_DURATION` seconds, then restored.

## Use case

A real partition (CNI bug, BGP flap, NetworkPolicy regression) makes
the daemon unreachable for a window without taking the pod down. The
daemon must answer its liveness probe (kubelet path, bypasses
NetworkPolicy), keep its in-flight buffer bounded, log no panic, and
resume ingestion once the partition heals.

## Architecture

```
manifests.yaml = NetworkPolicy ingress: [] scoped to perf-sentinel-daemon
                 -> blocks all cross-pod ingress
                 -> kubectl port-forward bypasses (kubelet proxy)
                 -> verify.sh can still curl localhost:14318/api/status
```

## Sequence

1. snapshot panic/FATAL log count (since=10s),
2. `kubectl apply -f manifests.yaml` (apply the strict ingress policy),
3. wait `PARTITION_DURATION` seconds, probe `/api/status` mid-partition,
4. `kubectl delete -f manifests.yaml` (heal),
5. wait `HEAL_DURATION` seconds, probe `/api/status` post-heal,
6. count panic/FATAL delta over the full window (since=2m).

## Inputs

| Variable             | Default | Notes                                  |
| -------------------- | ------- | -------------------------------------- |
| `PARTITION_DURATION` | 30      | seconds the partition stays applied    |
| `HEAL_DURATION`      | 30      | seconds after heal before final probe  |

## Verdict

PASS when:

- `/api/status` answers during the partition (via port-forward, which
  bypasses pod NetworkPolicies),
- `/api/status` answers after the heal,
- panic/FATAL log delta <= 0.

FAIL surfaces the daemon log tail in the report.

## Why this is conservatoire

The daemon in watch mode is a passive ingestor: it has no outbound
calls to backends except the optional Electricity Maps lookup. A
network partition that blocks ingress is therefore not expected to
crash anything, only to halt the events_processed counter for the
window. The scenario validates that this is actually what happens:
the absence of crashes confirms the daemon is independent from any
backend pull side-effect.

## Runtime prerequisites

- Lab bootstrap done (Calico is running): `make up-cni && make seed-services`.
- Daemon port-forward live: `./scripts/port-forward.sh start`.
- The cluster CNI must enforce NetworkPolicy. Verified by the existing
  `make verify-network-policies` target.
