# Resources

Estimated RAM and CPU usage once the stack is stable, with no
application traffic. Numbers are based on a macOS Apple Silicon
laptop (24 GiB) with Docker Desktop allocated 8 GiB.

## Bootstrap path

Since the CNI migration to Cilium (see [NETWORK-POLICIES.md](NETWORK-POLICIES.md)),
the default bootstrap target is `make up-cni`. The legacy `make up`
redirects to it with a deprecation note. The reason: `cluster/k3d-config.yaml`
disables Flannel and the k3s NetworkPolicy controller, so a plain
`scripts/bootstrap.sh` run produces NotReady nodes (no CNI installed).

`make up-cni` chains four steps:

1. `k3d cluster create --config cluster/k3d-config.yaml`.
2. `scripts/install-cni.sh` (Cilium 1.19.3 by default, Calico fallback).
3. `scripts/bootstrap.sh` (observability stack, Postgres, perf-sentinel daemon).
4. `kubectl apply -f manifests/network-policies.yaml` (zero-trust NetworkPolicy).

For ad-hoc debug of a non-network problem, run `scripts/bootstrap.sh`
directly on a cluster you have prepared with another CNI yourself. There
is no supported `make up` Flannel path anymore.

## Footprint per component (S1)

| Component | Resident RAM | CPU steady state | Notes |
| --- | --- | --- | --- |
| k3d (3 nodes + control plane) | ~1.5 GiB | ~0.30 core | containerd + k3s overhead |
| PostgreSQL 18.3 | ~300 MiB | ~0.05 core | 1 instance, 3 schemas |
| Tempo single-binary 2.9 (direct manifest) | ~600 MiB | ~0.10 core | idle |
| Prometheus | ~800 MiB | ~0.15 core | 7d retention, 15-30s scrape |
| Grafana 13.0.1 | ~200 MiB | ~0.05 core | dashboards bundled |
| OTel Collector contrib (DaemonSet x3) | ~600 MiB | ~0.15 core | ~200 MiB per node |
| perf-sentinel daemon | ~150 MiB | ~0.05 core | correlation enabled |
| **Total S1** | **~4.2 GiB** | **~0.85 core** | measured, not idle theoretical |

The original brief estimated 3.8 GiB without accounting for the
3 OTel Collector DaemonSet instances (1 per node, 200 MiB each
instead of 200 MiB total). Real usage is closer to 4.2 GiB.

## Projected S2 footprint

S2 will add 3 Java 25 + Spring Boot 4 services in the `shop`
namespace, instrumented via the OpenTelemetry Java agent. Per-service
estimate:

| Component (S2) | Resident RAM | CPU steady state |
| --- | --- | --- |
| `orders` (Spring Boot 4 + OTel agent) | ~500 MiB | ~0.10 core |
| `payments` (same) | ~500 MiB | ~0.10 core |
| `notifications` (same) | ~500 MiB | ~0.10 core |
| Synthetic load (k6, transient) | ~200 MiB | ~0.20 core peak |
| **S2 subtotal** | **~1.7 GiB** | **~0.40 core** |

## Projected S3 footprint

S3 will add GitLab CE self-hosted via Helm. Estimate:

| Component (S3) | Resident RAM | CPU steady state |
| --- | --- | --- |
| GitLab Webservice + Sidekiq | ~3.5 GiB | ~0.40 core |
| GitLab bundled Postgres + Redis | ~1.5 GiB | ~0.20 core |
| GitLab Runner | ~500 MiB | ~0.05 core (idle) |
| **S3 subtotal** | **~5.5 GiB** | **~0.65 core** |

## Cumulative total

| Phase | RAM | CPU | Headroom on Mac M4 24 GiB |
| --- | --- | --- | --- |
| S1 alone | ~4.2 GiB | ~0.85 core | comfortable |
| S1 + S2 | ~5.9 GiB | ~1.25 core | comfortable |
| S1 + S2 + S3 | ~11.4 GiB | ~1.90 core | tight but okay |

Allocate at least 12 GiB to Docker Desktop when chaining S1 + S2 + S3.

## Pinned versions (snapshot 2026-05-01)

| Component | Version | Source |
| --- | --- | --- |
| k3d | 5.x (5.8.3 verifie 2026-05-01) | brew install k3d |
| Kubernetes (k3s) | v1.35.4-k3s1 | pinned in cluster/k3d-config.yaml |
| Cilium | 1.19.3 | helm repo cilium |
| PostgreSQL | 18.3-alpine | docker.io/library/postgres |
| Tempo (binary) | 2.10.5 | image grafana/tempo:2.10.5, direct manifest |
| kube-prometheus-stack | 84.4.0 | helm repo prometheus-community |
| Grafana | 13.0.1 | explicit image override |
| opentelemetry-collector (chart) | 0.153.0 | helm repo open-telemetry |
| OTel Collector contrib (image) | 0.151.0 | bundled |
| OTel Java agent | 2.27.0 | services/shared-dockerfile/Dockerfile |
| Spring Boot starter parent | 4.0.6 | services/pom.xml (latest GA) |
| eclipse-temurin (Java build) | 25-jdk-alpine | docker.io/library/eclipse-temurin |
| distroless/java25 (runtime) | nonroot | gcr.io/distroless/java25 |
| k6 | 1.7.1 | grafana/k6:1.7.1 |
| GitLab CE chart | 9.11.2 | helm repo gitlab |
| perf-sentinel | 0.5.16 | ghcr.io/robintra/perf-sentinel |

## Note on daemon memory

The upstream perf-sentinel chart sets `requests: 16Mi / limits: 64Mi`.
The lab runs with `correlation.enabled = true` and
`max_active_traces = 10000`, which can exceed 64 MiB under S2 load.
Limits are bumped to `requests: 128Mi / limits: 256Mi`. If OOM kills
return in S2, raise to 512 MiB or lower `max_active_traces`.
