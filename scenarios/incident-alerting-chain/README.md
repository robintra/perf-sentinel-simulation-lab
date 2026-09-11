# incident-alerting-chain

Where an incident delivery actually comes from, and the credential that gets it
through the door.

## Why it exists

0.20.0 gave the daemon an intake at `POST /api/incidents`, and
[`incident-window-capture`](../incident-window-capture/) proves what it does
with a delivery: the freeze, the settle, the idempotent repost, the archive.
What no scenario proved is where that delivery comes from. Both incident
scenarios build the Alertmanager envelope by hand in python, and
`hub-incidents-mirror` says so itself: "The envelope is hand-built to the shape
the daemon accepts. That a real Alertmanager receiver posts exactly this is a
deployment concern." `docs/SCENARIOS.md` listed "Alertmanager itself" under
what is deliberately not asserted.

0.22.0 ships that missing half: two example files, one per Kubernetes operator,
carrying four alert rules and the receiver that posts them. The receiver
authenticates with a bearer token, and that is not a style choice. Neither
`AlertmanagerConfig` nor `VMAlertmanagerConfig` can send an arbitrary header,
so neither can send `X-API-Key`. Both carry a bearer credential, which is why
the daemon started accepting `Authorization: Bearer` on every key-gated route.

Three of the four links in that chain live outside the product repo: the CRD
schema, the operator that renders it, and the Alertmanager that delivers it.
This scenario is the only place they are exercised.

`make verify-incident-alerting-chain`. Legs A to F are self-contained (python3,
promtool, kubeconform) and take seconds. Legs G to I need a cluster with a
daemon under test, and take around ten minutes, most of it waiting for
Alertmanager's own group intervals.

## What it asserts

**A, B and C, the rules on their own.** promtool accepts both files, the two
files carry byte-identical rules (so everything proved on one is proved on its
twin), and `fixtures/rules-unit-tests.yaml` drives seven cases over synthetic
kube-state-metrics series. Three of those seven are claims the example files
make in prose and cannot demonstrate: that the oom and restart rules exclude
each other, that the saturation rule is **permanently silent** on a container
with no memory limit, and that both many-to-one joins survive a
kube-state-metrics scraped on two instances.

**D, the CRD.** The example file states as fact that `AlertmanagerConfig`'s
`httpConfig` has no field for an arbitrary header and does carry a bearer
token. That is an assertion about a third-party operator, shipped to users. It
is read back out of the CRD the cluster actually admits. `proxyConnectHeader`
is not a counter-example and is named as such: it reaches a proxy, never the
receiver.

**E, the twin's spelling.** No VM operator runs here, so no schema admits that
file. What actually breaks a hand-maintained twin is a camelCase key carried
across from the prometheus-operator file, which VM drops without a word.

**F, what kubeconform does not say.** With no CRD schema it marks all four
resources Skipped and exits 0. Recorded as a SKIP, never as a PASS: a scenario
reporting success for a tool that validated nothing is the cleanest false green
there is.

**G, an A/B that is really an A/B.** A second daemon runs beside the one under
test on the released 0.21.0 digest, sharing its ConfigMap and its Secret, so
the only difference between them is the image. The guard matters more than it
looks: `Cargo.toml` still carries 0.21.0 on this branch, so `/api/status`
reports the same version on both pods and **the version is not a
discriminant**. The 401 body is. The twin must answer 200 to the header key
before its 401 on a bearer proves anything, otherwise a dead pod, a wrong key
or a disabled section would read the same.

**H, the one review fix that changes behaviour.** The deploy rule joins a
replicaset's creation time to its owner with a many-to-one `group_left`. Before
the review, the right-hand side was not aggregated. Scaled to two replicas,
kube-state-metrics publishes that series twice per (namespace, replicaset) and
PromQL refuses the match: the rule does not alert late, it **fails to
evaluate** and posts nothing at all. The shipped rule and a copy of its
pre-review expression run side by side, and
`prometheus_rule_evaluation_failures_total` separates them.

**I, the chain.** The `PrometheusRule` goes in **byte for byte**: the victim in
`manifests.yaml` names its container `app` precisely so the shipped file
applies unedited, and no other workload in this lab does. The rules fire on
real kube-state-metrics and cAdvisor series and derive `service` from the pod
name, which is the OTLP `service.name` the findings carry. Then the namespace
matcher, both ways:

- At the chart default, the operator appends a matcher on the **resource's**
  namespace while the alert carries the **observed workload's**. The route
  resolves to `null`. The alert is live in Alertmanager, no incident arrives,
  and **no refusal is counted either**, because the delivery never leaves.
  An operator has nothing anywhere to read.
- Disabled, the same alert with the same `startsAt` reaches the receiver, a
  real Alertmanager sends the bearer credential, and the incident comes back
  from `GET /api/incidents` with its window frozen and its findings attached.

The findings are seeded **before** any alert fires, and a non-empty `findings`
array is asserted. An incident that freezes nothing is recorded all the same
and reports no error anywhere, which is the quietest way this chain can look
green and be worthless.

## What it does not assert

**The VictoriaMetrics rendering.** The twin file's schema is checked
structurally (leg E) and its rules are proved identical to the ones leg C
exercises, but no VM operator turns `bearer_token_secret` into an
`Authorization` header here. Installing the VM operator would mean a second
complete monitoring stack, and its converter turns existing `PrometheusRule`
and `ServiceMonitor` objects into VM resources by default, which collides with
every selector this lab leaves open.

**`PerfSentinelMemorySaturation` in the cluster.** Its `for: 5m` needs seven to
nine minutes of wall clock, and holding a container at 91 percent of its limit
without tipping into an OOM is unstable by nature. Leg C proves its behaviour,
including the silence with no memory limit, which is the part that matters.

**The real fleet.** The victim is built so the rules apply unedited, which
means the example's second assumption, that a Deployment's name equals its OTLP
`service.name`, is proved against a Deployment made for it rather than against
`order-service`. The lab's own charts happen to satisfy that assumption too,
but their containers are named after their chart, so the rules would need the
one edit the file says they need.

**The inhibition trap.** The chart's default `inhibit_rules` silence
`severity: info` alerts in a namespace where `InfoInhibitor` fires, and all
four shipped rules are `severity: info`. `defaultRules.create: false` means
`InfoInhibitor` does not exist here, so the trap cannot be observed. Turning
the default rules on would bring dozens of cluster alerts into the lab.

**Alertmanager in HA.** One replica. Gossip deduplication and double deliveries
from a three-node Alertmanager are not exercised. The idempotence of a repeated
delivery is covered by `incident-window-capture`, and incidentally here, since
the twin's permanent 401 makes Alertmanager retry the group every minute.

## Shared state, and putting it back

Two cluster-wide settings are changed: Alertmanager's
`alertmanagerConfigMatcherStrategy` and the kube-state-metrics replica count. A
trap restores both, and the pre-flight also resets them on the way in, so a run
killed between its legs cannot poison the scenarios after it. If the trap never
ran:

```bash
kubectl -n observability patch alertmanager kube-prometheus-stack-alertmanager \
  --type=merge -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"OnNamespace"}}}'
kubectl -n observability scale deploy/kube-prometheus-stack-kube-state-metrics --replicas=1
kubectl delete -f scenarios/incident-alerting-chain/manifests.yaml
kubectl -n observability delete prometheusrule perf-sentinel-incidents perf-sentinel-incidents-control
kubectl -n observability delete alertmanagerconfig perf-sentinel-incidents
kubectl -n observability delete secret perf-sentinel-incidents-key
kubectl -n observability delete job tracegen-psbearer
```

## Prerequisites

`make up` for the cluster, `make seed-tracegen` for the load-generator image the
victim and the seed Job both run, and `make seed-daemon-local` for a daemon
under test that accepts a bearer token. Leg G fails with the command to run
when that last one is missing, rather than letting the chain fail later for a
reason that looks like something else. `make seed-services` is **not** needed:
this scenario brings its own workload.
