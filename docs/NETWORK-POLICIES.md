# Network segmentation with Cilium and NetworkPolicy

The lab runs on k3d, which ships Flannel by default. Flannel
silently ignores `NetworkPolicy` resources: any rule applied has
no effect on traffic. Production clusters at most Onepoint customers
run a CNI that does enforce NetworkPolicy, so the lab swaps Flannel
for Cilium and applies zero-trust segmentation that mirrors what
perf-sentinel will actually be deployed under.

## What this validates

- The lab daemon, services, observability stack, and GitLab CE keep
  working under deny-by-default networking.
- A pod that lacks the `app.kubernetes.io/part-of: perf-sentinel-lab`
  label cannot reach Postgres, even from the `shop` namespace.
- The daemon's egress to `api.electricitymaps.com` and the GitLab
  runner's egress to `github.com` survive the segmentation.
- Prometheus still scrapes every ServiceMonitor target.

## CNI choice

Cilium 1.19.3 is the default. It runs in eBPF mode with
`kubeProxyReplacement=false` (kept this way because Docker Desktop's
host networking does not handle Cilium's full kube-proxy
replacement reliably on arm64). Hubble is enabled with the relay
running and the UI off; turn the UI on with `make hubble-ui` when
debugging a denial.

Calico is the documented manual fallback. To use it, edit
`scripts/install-cni.sh` and rerun `make up-cni calico`. The CNI
choice is recorded in `cluster/.cni-active` (gitignored).

## Install

The order below matters: `make up-gitlab` and
`make seed-electricity-maps` must run AFTER `make up-cni` so the
NetworkPolicy is in place when these workloads first start. If you
flip the order, GitLab CE pods will boot under deny-by-default and
some of them (kas, runner) will hit retries and crashloops while the
chart-mesh policies catch up.

```bash
make down                    # tear down any prior cluster
make up-cni                  # k3d + Cilium + bootstrap + apply-network-policies
make seed-services           # 3 Java services in shop, segmented
make seed-electricity-maps   # optional, EM token Secret
make up-gitlab               # optional, GitLab CE in gitlab-ce ns
make seed-gitlab-project     # optional, perf-sentinel-template-test
make verify-network-policies # confirm deny-by-default + allowed paths
```

`make up-cni` chains `k3d cluster create` (Flannel disabled),
`scripts/install-cni.sh`, the unmodified `scripts/bootstrap.sh`, and
`kubectl apply -f manifests/network-policies.yaml`. The chart's
default `make up` (Flannel) is preserved for debugging non-network
issues.

### Recovery after a docker container restart

When Docker Desktop sleeps or the host runs out of memory, the k3d
control plane container may restart. On wake, Cilium agents re-init
their eBPF programs but the endpoint cache can drift, leaving pod-
to-pod NetworkPolicy enforcement desynced (typical symptom: shop
pods cannot resolve `postgres.db.svc.cluster.local`, `nslookup`
times out from inside the namespace).

```bash
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n shop rollout restart deployment/order-service \
  deployment/payment-service deployment/notification-service
```

This is faster than `make reset-cni` (full teardown) when the
underlying cluster state is otherwise healthy.

## What the policies do, namespace by namespace

| Namespace | Default | Egress | Ingress |
| --- | --- | --- | --- |
| `shop` | deny-all | DNS, Postgres in `db`, OTel collector in `observability` | Prometheus scrape |
| `db` | deny-all | DNS | Postgres from `shop` lab pods, Prometheus scrape |
| `observability` | deny-all | DNS, Tempo intra-ns, daemon intra-ns, Electricity Maps API (FQDN) | OTel from `shop`, Prometheus scrape |
| `gitlab-ce` | deny-all | DNS, full intra-ns mesh (release=gitlab + bitnami sub-charts), GitHub + registry.gitlab.com (FQDN, runner only) | webservice 8181 from any pod, Prometheus scrape |

The `manifests/network-policies.yaml` file lists the rules in the
order they appear in the table. Each rule has a header comment
explaining its rationale.

## FQDN egress

Cilium's `CiliumNetworkPolicy` with `toFQDNs` resolves DNS at policy
evaluation time, so we can authorize outbound traffic by hostname
instead of CIDR. The lab uses this for:

- `api.electricitymaps.com` (perf-sentinel daemon)
- `github.com`, `*.github.com`, `objects.githubusercontent.com`,
  `registry.gitlab.com` (GitLab runner build pods)

Cilium's DNS proxy intercepts pod DNS queries to populate the FQDN
allowlist. The proxy listens on the same path as kube-dns; if you
see DNS resolutions failing in your application logs after applying
the policies, run `cilium hubble observe --verdict DROPPED -t l7`
to see whether the DNS proxy is bouncing queries.

When using Calico as a fallback CNI, replace the FQDN egress rules
with `ipBlock: 0.0.0.0/0` on port 443 (less precise but portable).

## Debugging

```bash
cilium status                                        # overall health
cilium connectivity test                             # exhaustive matrix (~3 min)
cilium hubble observe --verdict DROPPED              # live drops
cilium hubble observe --pod observability/perf-sentinel-daemon
make hubble-ui                                        # browser UI on :12000
```

If a pod hangs on a connection that should be allowed, the most
common pattern is:

1. The policy's `podSelector` does not match the pod's actual
   labels. Run `kubectl get pod <name> --show-labels` and
   reconcile.
2. The `namespaceSelector` does not match. The lab uses
   `kubernetes.io/metadata.name: <ns>`, which is the implicit label
   Kubernetes adds to every namespace.
3. DNS resolution itself is blocked, so the connection times out
   before reaching the destination policy. Check the
   `allow-dns-egress` rule for that namespace.

## Reset and iterate

```bash
make remove-network-policies   # drop policies, keep cluster + workloads
# edit manifests/network-policies.yaml
make apply-network-policies
make verify-network-policies
```

This loop avoids tearing down the cluster on every policy
adjustment.

## Limitations

- The chart's `kubeProxyReplacement=false` means Cilium relies on
  k3s's bundled kube-proxy. If you migrate this lab to a managed
  Kubernetes (EKS, GKE), switch to `true` for the eBPF service
  fast-path.
- The GitLab CE in-cluster install does not expose a top-level
  `global.networkpolicy.enabled` knob (verified on chart 9.11.2),
  so the mesh policies are written by hand here.
- Hubble UI is off by default to keep the lab footprint small. The
  CLI (`cilium hubble observe`) is enough for most debugging.
- `toFQDNs` requires the Cilium DNS proxy. Replacing Cilium with
  Calico requires hand-translating those rules to CIDR blocks.

## Verify

`make verify-network-policies` runs five assertions:

1. An ephemeral unlabeled pod in `shop` cannot reach Postgres
   (negative test, exit 1 expected via `nc -z` timeout).
2. The `order-service` pod can reach Postgres.
3. The perf-sentinel daemon's `green_summary.scoring_config` is
   populated, which proves the egress to `api.electricitymaps.com`
   is open.
4. The GitLab runner can reach `github.com:443` (skipped if
   GitLab CE is not deployed).
5. Prometheus reports `up{job="perf-sentinel-daemon"}=1`,
   confirming the scrape ingress path.
