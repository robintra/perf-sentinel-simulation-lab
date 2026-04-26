# Helm values

This directory holds the Helm values files consumed by
`scripts/bootstrap.sh`. Chart versions are pinned in the bootstrap
script and repeated in a comment at the top of each file.

| File | Chart | Pinned version | Role |
| --- | --- | --- | --- |
| `kube-prometheus-stack.yaml` | `prometheus-community/kube-prometheus-stack` | 84.1.0 | Prometheus + Grafana + operator, no Alertmanager nor Thanos. |
| `otel-collector.yaml` | `open-telemetry/opentelemetry-collector` | 0.152.0 | DaemonSet contrib Collector, exports to Tempo and the daemon. |
| `perf-sentinel-daemon.yaml` | (reserved) | n/a | Placeholder. The daemon ships via `manifests/perf-sentinel-daemon.yaml`. |

Tempo and the perf-sentinel daemon are deployed via direct manifests
in `manifests/`, no Helm chart involved. Both Grafana charts
(`grafana/tempo` and `grafana/tempo-distributed`) are flagged
`deprecated: true`, so the lab runs Tempo single-binary
(`-target=all`) via a concise standalone manifest.

## Bumping versions

```bash
helm repo update
helm search repo prometheus-community/kube-prometheus-stack --versions | head
helm search repo open-telemetry/opentelemetry-collector --versions | head
```

For Tempo, check the new image tags:

```bash
docker run --rm grafana/tempo:2.9.0 -version
# or look at https://github.com/grafana/tempo/releases
```

Update the comments at the top of each values file and the matching
constant in `scripts/bootstrap.sh`.
