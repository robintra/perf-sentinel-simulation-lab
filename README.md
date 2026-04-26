# perf-sentinel simulation lab

Local Kubernetes cluster preconfigured to validate perf-sentinel
against instrumented Java services. The lab ships an observability
stack, three Java 25 + Spring Boot 4 services that intentionally
exhibit performance anti-patterns, and a k6 driven validation
pipeline that asserts perf-sentinel correctly classifies each
pattern.

## What it is for

The project is an external consumer of perf-sentinel. It deploys a
local k3d cluster with OpenTelemetry Collector, Tempo, Prometheus,
Grafana, perf-sentinel daemon, PostgreSQL, plus three application
services in the `shop` namespace (`order-service`, `payment-service`,
`notification-service`) that produce the ten canonical anti-pattern
classes on demand via `/api/fault/*` endpoints.

`make seed-services && make validate-findings` runs the ten k6
scenarios in sequence and reports how many anti-patterns
perf-sentinel detected on the expected service.

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

# Service deployment (depends on `make up` first)
make seed-services       # build, import, helm install the 3 Java services
make teardown-services   # helm uninstall the 3 services
make inject-all          # alias of validate-findings
make validate-findings   # run 10 k6 scenarios, assert findings, write tmp/validation-report.md
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

## Java services and anti-patterns

Three Spring Boot 4 services live in the `shop` namespace. Each
exposes one `/api/fault/<pattern>` endpoint per anti-pattern it owns,
plus actuator health and prometheus endpoints.

| Service | Port | Postgres schema | Faults exposed |
| --- | --- | --- | --- |
| order-service | 8080 | orders | n_plus_one_sql, redundant_http, slow_sql, pool_saturation |
| payment-service | 8081 | payments | redundant_sql, slow_http |
| notification-service | 8082 | notifications | n_plus_one_http, excessive_fanout, chatty_service, serialized_calls |

Together they cover the ten canonical detection classes of
perf-sentinel 0.5.4. `make validate-findings` exercises all ten
through k6 Jobs running in-cluster and asserts that each scenario
produces at least one matching finding on the expected service.

## Roadmap

- **S1 (shipped)**: k3d cluster + observability + Postgres + daemon.
- **S2 (shipped)**: 3 Java 25 + Spring Boot 4 services with
  `/api/fault/*` endpoints. 10 k6 scenarios. validate-findings
  pipeline.
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
