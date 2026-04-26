# Troubleshooting

Common errors hit during bootstrap or operation, with their diagnosis
and fix.

## `k3d cluster create` fails with "port already bound"

```
ERRO[0000] Failed Cluster Start: Failed to add one or more helpers
ERRO[0000] Bind for 0.0.0.0:3000 failed: port is already allocated
```

Another process is already listening on 3000, 14318, 80, or 443.
Identify the culprit:

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN
lsof -nP -iTCP:14318 -sTCP:LISTEN
```

Either free the port or edit `cluster/k3d-config.yaml` to map a
different host port (for example `3001:3000`), then run
`make reset`.

## `docker pull ghcr.io/robintra/perf-sentinel:0.5.4` fails

Most likely the GHCR image is private or requires a specific account.
Authenticate docker against GHCR:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <username> --password-stdin
```

If the image does not exist in the public registry at all, fall back
to a local source build:

```bash
cd $PERF_SENTINEL_REPO_PATH
cross build --release --target x86_64-unknown-linux-gnu -p sentinel-cli
mkdir -p build/linux-amd64
cp target/x86_64-unknown-linux-gnu/release/perf-sentinel build/linux-amd64/
docker buildx build --platform linux/amd64 --build-arg TARGETARCH=amd64 \
  -t perf-sentinel:0.5.4 .
```

Then re-run `make up`.

## node-exporter pods stuck `FailedCreate` PodSecurity

If `kubectl get daemonset -n observability` reports `READY 0/3` and
`kubectl describe daemonset` mentions:

```
violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true...)
```

the `observability` namespace is enforcing `baseline`. node-exporter
needs `hostNetwork`, `hostPID`, and `hostPath` volumes, which
baseline forbids. The shipped manifest already sets `privileged` on
this namespace, but if someone overrode the label:

```bash
kubectl label namespace observability \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
kubectl rollout restart daemonset \
  -n observability kube-prometheus-stack-prometheus-node-exporter
```

## `localhost:3000` or `localhost:14318` does not respond

The k3d port mappings (`80:80`, `3000:3000`, `14318:14318`) target
NodePort or LoadBalancer Services. The lab uses ClusterIP Services
plus `--disable=servicelb`, so the port mappings alone do not work.
`bootstrap.sh` starts background `kubectl port-forward` processes via
`scripts/port-forward.sh`.

If the host endpoints do not respond after `make up`:

```bash
./scripts/port-forward.sh stop
./scripts/port-forward.sh start
ls tmp/pf-*.pid
```

To stop cleanly: `./scripts/port-forward.sh stop` (or `make down`,
which does it automatically).

## `k3d image import` fails with `content digest not found`

Intermittent k3d bug on Docker Desktop. Output looks like:

```
ERRO failed to import images in node 'k3d-perf-sentinel-lab-server-0':
ctr: content digest sha256:...: not found
```

`manifests/perf-sentinel-daemon.yaml` references the GHCR image
directly (`ghcr.io/robintra/perf-sentinel:0.5.4`), so kubelets can
pull at run time. `bootstrap.sh` continues even if the k3d import
fails.

If the import is required for offline operation, recreate the
cluster:

```bash
make down
docker rmi ghcr.io/robintra/perf-sentinel:0.5.4
docker pull ghcr.io/robintra/perf-sentinel:0.5.4
make up
```

## `helm upgrade kube-prometheus-stack` times out

```
Error: UPGRADE FAILED: timed out waiting for the condition
```

Often caused by a `prometheus-operator` pod waiting for its admission
webhook. The lab disables webhooks
(`prometheusOperator.admissionWebhooks.enabled: false`). If the
issue persists:

```bash
kubectl -n observability describe pod -l app.kubernetes.io/name=prometheus-operator
kubectl -n observability logs -l app.kubernetes.io/name=prometheus-operator
```

Common cause: a k3d node that ran out of memory. Use `docker stats`
to check.

## perf-sentinel-daemon pod in `CrashLoopBackOff`

```bash
kubectl -n observability describe pod -l app.kubernetes.io/name=perf-sentinel-daemon
kubectl -n observability logs -l app.kubernetes.io/name=perf-sentinel-daemon --previous
```

Causes seen in practice:

- Image not available to the cluster: re-run
  `k3d image import ghcr.io/robintra/perf-sentinel:0.5.4 -c perf-sentinel-lab`
  or check that the kubelet can reach GHCR.
- Invalid TOML config: check the key names in
  `manifests/perf-sentinel-daemon.yaml` (`[detection]` not `[detect]`,
  `n_plus_one_min_occurrences` not `n_plus_one_sql_threshold`).
- Liveness probe failing: if `/health` does not respond within
  `initialDelaySeconds`, the pod is killed. Bump it to 10 s on slower
  hosts.

## Postgres stuck `Pending`

```bash
kubectl -n db describe statefulset postgres
kubectl -n db describe pvc data-postgres-0
```

Most common cause: no `local-path` StorageClass. Verify:

```bash
kubectl get storageclass
```

If `local-path` is missing, k3s did not start its provisioner.
Destroy the cluster and re-run `make up`.

## Grafana does not load the `perf-sentinel-overview` dashboard

Verify the ConfigMap is properly labeled:

```bash
kubectl -n observability get configmap perf-sentinel-dashboards \
  --show-labels
```

The `grafana_dashboard=1` label must be present, otherwise the
sidecar ignores it. Recreate the ConfigMap manually:

```bash
kubectl -n observability create configmap perf-sentinel-dashboards \
  --from-file=manifests/grafana-dashboards/ \
  --dry-run=client -o yaml | \
  kubectl label --local -f - grafana_dashboard=1 -o yaml --dry-run=client | \
  kubectl apply -f -
```

## `perf-sentinel-overview` stays empty after `make up`

Three possible causes, in order:

1. No traffic. In S1 nothing generates traces, so most panels stay at
   zero. Expected. To test, send a manual span with `otel-cli` or
   wait for S2.
2. ServiceMonitor not scraped by Prometheus. In Grafana under
   `Status > Targets`, the `perf-sentinel-daemon` target must be
   `UP`. Otherwise check the `release: kube-prometheus-stack` label
   on the ServiceMonitor and the Prometheus selector.
3. Prometheus datasource misconfigured. In Grafana under
   `Connections > Data sources > Prometheus`, run `Save & test`.

## `make psql` cannot connect

```
psql: error: connection to server at "postgres" failed
```

First test from inside the cluster:

```bash
kubectl -n db run pgcheck --rm -it --restart=Never \
  --image=postgres:18.3-alpine -- \
  psql -h postgres -U lab -d lab
```

If that works but `make psql` does not, check `.postgres-password`
(no trailing newline, mode 0600).

## perf-sentinel reports `suggested_fix: null` and `source_endpoint: unknown`

**Resolved in perf-sentinel 0.5.6.** Framework detection now uses two
complementary signals: the OpenTelemetry instrumentation scope chain
collected from each span's parent path (catches `spring-data`,
`hibernate`, `quarkus`, `spring-webflux`, `r2dbc`, `helidon`, `jdbc`),
plus user-code naming conventions on the JPA rule (`*Repository`,
`*Repo`, `*Dao` suffixes). The lab pins 0.5.6 by default and JPA
findings now carry `suggested_fix.framework = "java_jpa"` with a
populated `recommendation`. Section kept below for users still on 0.5.5
or earlier.

### Pre-0.5.6 behavior

perf-sentinel infers the framework (`java_jpa`, `java_quarkus`, `csharp_ef_core`, etc.) from the `code.namespace` attribute on the finding's primary span. For SQL findings the primary span is a JDBC span, which the OpenTelemetry Java agent does not currently enrich with the originating user-code namespace.

In our trace tree:

```
HTTP span             (http.route present)
  └─ Controller span  (code.namespace=com.perfsim.order.web.FaultController)
      └─ Hibernate Query span    (no code.* attributes)
          └─ JDBC span           (no code.* attributes; perf-sentinel reads here)
```

perf-sentinel 0.5.4 does not walk up the parent chain, so it sees no namespace and emits no `suggested_fix`. perf-sentinel 0.5.5 added the parent walker but the table `JAVA_RULES` only matched framework packages, so the user-code namespace surfaced by the walker (e.g. `com.example.OrderRepository`) still failed to match. perf-sentinel 0.5.6 closes both gaps.

`source_endpoint` is similarly read from the immediate parent (Hibernate Query span) rather than from the HTTP server span, hence the `unknown` value.

Historical workarounds explored and dismissed:

- `OTEL_INSTRUMENTATION_COMMON_EXPERIMENTAL_CONTROLLER_TELEMETRY_ENABLED=true` and friends. Add code attributes to controller and repository spans, but not to JDBC spans, so perf-sentinel still sees nothing on the spans it inspects.
- Modifying perf-sentinel to walk parents. Implemented in 0.5.5.
- Extending the framework rules to recognize user-code conventions and using the OpenTelemetry instrumentation scope as a primary signal. Implemented in 0.5.6.

## OTel Collector exporter `compression: none` against the daemon

**Resolved in perf-sentinel 0.5.5.** The daemon's `/v1/traces` handler
now decompresses gzipped request bodies via `tower-http`'s
`RequestDecompressionLayer`, matching the OTLP HTTP spec. The lab's
`helm/values/otel-collector.yaml` no longer sets `compression: none`
on the `otlphttp/perf_sentinel` exporter and lets the OTel default
(gzip) apply.

### Pre-0.5.5 behavior

The daemon used to reject any gzipped OTLP HTTP body with HTTP 400
because `prost::Message::decode` does not understand gzip. Stack
operators on 0.5.4 had to set `compression: none` on every Collector
exporter targeting the daemon, otherwise zero traces reached it.

## Reset to a clean state

```bash
make down
docker rmi ghcr.io/robintra/perf-sentinel:0.5.4
docker volume prune
rm -f .postgres-password
make up
```
