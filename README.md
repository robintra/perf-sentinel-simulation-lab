# perf-sentinel simulation lab

Local Kubernetes cluster preconfigured to validate perf-sentinel
against instrumented Java services. Sprint S1 ships only the
observability infrastructure, no application services.

## What it is for

The project is an external consumer of perf-sentinel. It deploys a
local k3d cluster and the surrounding stack: OpenTelemetry Collector
to ingest traces, Tempo to store them, Prometheus and Grafana for
visualization, perf-sentinel daemon to detect IO anti-patterns in
real time, and PostgreSQL ready to host the Java services in
sprint S2.

The end goal is a reproducible environment for measuring
perf-sentinel's true and false positive rates against realistic
workloads.

## Prerequisites

- macOS (Apple Silicon or Intel) or Linux x86_64.
- Docker Desktop ≥ 4.30 or Colima ≥ 0.7. Allocate at least 8 GiB of
  RAM to Docker.
- `brew install k3d kubectl helm` (minimum versions: k3d 5.x, kubectl
  1.30+, helm 3.14+ or 4.x).
- `python3` (preinstalled on recent macOS) for JSON formatting in
  `make status`.
- Network access on first `make up` (Helm charts and the perf-sentinel
  GHCR image).

## Quickstart

```bash
git clone <this-repo> perf-sentinel-simulation-lab
cd perf-sentinel-simulation-lab
make up
open http://localhost:3000   # Grafana, admin / admin
```

`make up` takes about 5 to 8 minutes on the first run. Subsequent
runs are faster thanks to Docker and Helm cache.

## Architecture

High-level view:

```
  Java services (S2)  ─┐
                        │ OTLP gRPC/HTTP
                        ▼
                  OTel Collector (DaemonSet)
                  ├─ otlphttp ──> Tempo  (trace storage)
                  ├─ otlphttp ──> perf-sentinel daemon  (findings)
                  └─ prometheus :8889/metrics
                                  ▲
   Prometheus  ──── ServiceMonitor scrape ─── perf-sentinel /metrics
       │
       └──> Grafana datasources: Prometheus + Tempo
```

Full details and rationale: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What you get

| Service | URL | Credentials |
| --- | --- | --- |
| Grafana | http://localhost:3000 | admin / admin |
| perf-sentinel daemon API | http://localhost:14318 | none (local lab) |
| Postgres (cluster-internal) | postgres.db.svc.cluster.local:5432 | user `lab`, see `.postgres-password` |

The host endpoints rely on `kubectl port-forward` started in the
background by `make up`. Stop them with `./scripts/port-forward.sh stop`
or `make down`.

Namespaces:

- `observability`: Tempo, Prometheus, Grafana, OTel Collector,
  perf-sentinel daemon.
- `db`: PostgreSQL 18.3 with schemas `orders`, `payments`,
  `notifications`.
- `shop`: empty in S1, reserved for the Java services in S2.
- `ci`: empty in S1, reserved for GitLab/Forgejo in S3/S4.

## Make targets

```bash
make up           # full bootstrap
make down         # tear down the cluster
make reset        # down then up
make validate     # offline syntactic validation (manifests + helm + dashboards)
make status       # pod status and daemon endpoint health (curl)
make logs         # tail observability namespace logs
make grafana      # open Grafana in the browser
make psql         # open a psql shell against the lab database
make inspect      # launch the perf-sentinel TUI (host binary required)
make ps           # docker ps for k3d containers
make clean-images # docker image prune
make help         # list targets
```

## Verifications after `make up`

```bash
# 1. All pods Ready
kubectl get pods -A

# 2. Grafana reachable
open http://localhost:3000

# 3. perf-sentinel daemon responding
curl -s http://localhost:14318/api/status | python3 -m json.tool

# 4. No findings yet (expected in S1, no traffic)
curl -s http://localhost:14318/api/findings | python3 -m json.tool

# 5. Tempo ready
curl -s http://localhost:3200/ready

# 6. Postgres reachable from cluster
make psql
\dn

# 7. Daemon exposes Prometheus metrics
curl -s http://localhost:14318/metrics | grep '^perf_sentinel_'
```

## perf-sentinel configuration

The daemon is configured via the `perf-sentinel-daemon-config`
ConfigMap (mounted on `/etc/perf-sentinel/config.toml`). Lab defaults:

```toml
[daemon]
listen_address = "0.0.0.0"
listen_port_http = 14318
listen_port_grpc = 14317
max_active_traces = 10000
trace_ttl_ms = 60000

[daemon.correlation]
enabled = true
window_minutes = 5

[detection]
n_plus_one_min_occurrences = 5
```

Ports 14317/14318 (instead of the defaults 4317/4318) avoid confusion
with the standard OTLP ports used by Tempo and the OTel Collector.

To change these values, edit `manifests/perf-sentinel-daemon.yaml`,
re-apply with `kubectl apply -f`, then
`kubectl rollout restart deployment/perf-sentinel-daemon -n observability`.

## Roadmap

- **S1 (shipped)**: k3d cluster + observability + Postgres + daemon.
- **S2 (next)**: 3 Java 25 + Spring Boot 4 services instrumented to
  intentionally exhibit anti-patterns. Synthetic load via k6.
  Findings validation.
- **S3 (TBD)**: GitLab CE self-hosted via Helm to validate the
  perf-sentinel GitLab CI template.
- **S4 (optional)**: Forgejo + Forgejo Actions for the GitHub Actions
  template.

## Troubleshooting

Common errors (port already bound, GHCR pull failure, OOM, blank
dashboard, etc.) and fixes: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Resources

RAM/CPU estimate per component and per sprint:
[docs/RESOURCES.md](docs/RESOURCES.md).

## License

AGPL v3, aligned with perf-sentinel. See [LICENSE](LICENSE).
