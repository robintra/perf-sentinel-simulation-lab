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
carrying four alert rules and the receiver that posts them. 0.24.0 adds a fifth
group to each, a `perf_sentinel:untraced_services:1d` recording rule the four
alerts subtract with `unless on (service)`, so a workload the daemon has not
ingested over the last day raises no incident with nothing in it. The receiver
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
files carry byte-identical rules, the recording rule and its two-minute
interval included (so everything proved on one is proved on its twin), and
`fixtures/rules-unit-tests.yaml` drives ten cases over synthetic
kube-state-metrics series. Six of those ten are claims the example files make
in prose and cannot demonstrate: that the oom and restart rules exclude each
other, that the saturation rule is **permanently silent** on a container with
no memory limit, that both many-to-one joins survive a kube-state-metrics
scraped on two instances, that a workload with no
`perf_sentinel_service_io_ops_total` over the window raises nothing, and that
the same workload raises its alert again the moment
`perf_sentinel_service_io_ops_overflow_total` goes nonzero, which is the
fail-open direction and the one that decides whether a full service cap
silences a whole fleet, and that a pod a Job owns raises nothing even then.
trivy-operator names each scan Job's container after the one it scans, so
its scan pods match the container selector, and the record drops them only
from its next evaluation. The StatefulSet case carries its owner series, so
the Job clause is also shown to leave that pod to the daemon's refusal.

Every case publishes the `kube_pod_container_info` its pod would really carry,
so the record always has a left-hand side to subtract from. A case without it
passes because there is nothing to subtract rather than because the rule
behaves, which is the new suppression routed around instead of exercised. Each
service meant to look ingested publishes `perf_sentinel_service_io_ops_total`
beside it, and the three that do not leave it out on purpose: the StatefulSet
pod the record's own pod selector must keep out of its result, and the untraced
workload of the last three cases.

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

Both shipped groups are read there, the record's as well as the alerts'. A
failing record group is the quiet one: it leaves the record empty, every alert
then passes its `unless`, and leg I below reports exactly the alerts it reports
when everything works. A group Prometheus never loaded publishes no counter at
all, which reads the same as a group that evaluates cleanly, so the leg fails
on an absent group rather than counting it as zero.

**I, the chain.** The `PrometheusRule` goes in **byte for byte**, at the top of
leg H so that leg has something of it to read: the victim in
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

Since 0.24.0 that seeding decides whether the alert fires at all. The victim is
a `container="app"` workload like any other, so the recording rule counts it
among the candidates and drops it until `perf_sentinel_service_io_ops_total`
carries its service, which happens when the tracegen Job reaches the daemon and
Prometheus scrapes it. A fleet the daemon ingests is what the rules are written
for, and seeding first is what makes this victim one rather than the untraced
workload the record exists to silence.

Which is why the leg asserts that the Job **completed**, and not only that an
alert fired afterwards. The record reads `perf_sentinel_service_io_ops_total`
over a one-day window, so one successful run keeps the victim looking ingested
for the next twenty-four hours: a Job that stopped running tomorrow would leave
the alert firing and the leg green, on evidence this run did not produce. The
daemon's findings ring has the same memory for as long as the daemon is not
restarted. The Job's own `condition=complete` is the one signal that belongs to
the run reading it.

## What it does not assert

**The VictoriaMetrics rendering.** The twin file's schema is checked
structurally (leg E) and its rules are proved identical to the ones leg C
exercises, but no VM operator turns `bearer_token_secret` into an
`Authorization` header here. Installing the VM operator would mean a second
complete monitoring stack, and its converter turns existing `PrometheusRule`
and `ServiceMonitor` objects into VM resources by default, which collides with
every selector this lab leaves open.

Which leaves the fifth group's own operator trap unproved, and it is the
harshest one either file carries. The twin's header states that vmalert refuses
its **whole** rule configuration, every `VMRule` it selects included, when a
group holds a recording rule and the VMAlert sets no `spec.remoteWrite`: a
reload is rejected and a restart fails. An operator who copies the twin and
applies it without that field therefore loses far more than these four alerts,
and nothing here catches it. Leg E reads the file's spelling and leg D reads a
schema, neither reads a running vmalert. Set `spec.remoteWrite` on the VMAlert
before applying the twin.

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

`make up` for the cluster and `make seed-daemon-local` for a daemon under test
that accepts a bearer token. Leg G fails with the command to run when that
second one is missing, rather than letting the chain fail later for a reason
that looks like something else. `make seed-services` is **not** needed: this
scenario brings its own workload.

The load-generator image the victim and the seed Job both run comes from `make
seed-tracegen`, which `make verify-incident-alerting-chain` now depends on, as
the `limit-*` targets do. Without it neither pod starts, `imagePullPolicy:
Never` being what keeps this lab off any registry, and leg I then reports no
alert and no finding, which reads like a rule that stopped firing.
