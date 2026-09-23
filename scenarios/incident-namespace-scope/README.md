# incident-namespace-scope

An incident recorded for one Kubernetes namespace freezes the findings of that
namespace, not those of the same service in every tenant's namespace.

## Why it exists

On a fleet where each tenant runs the same service in its own namespace, one
rollout fires one alert per namespace, and the daemon records one incident per
namespace. Up to 0.24.0 the incident's `namespace` was a label: the freeze
screened the ring by service and window alone, so every one of those incidents
held the findings of every tenant, and each tenant's post-mortem read the
others'. 0.25.0 leaves out a finding whose grouping names a different
`k8s.namespace.name`, at reception and in the settle pass, wherever that
attribute sits in `[detection] grouping_attributes`. A finding that carries no
such attribute is kept, since nothing places it elsewhere.

`incident-window-capture` owns the intake and the window. This scenario owns
which findings of that window an incident with a namespace keeps.

`make verify-incident-namespace-scope`. Self-contained: a local release binary,
python3 and curl. No cluster, no Docker. Around 15 seconds. Run against 0.24.0
it fails seven of its twelve checks, the ones 0.25.0 changed. The other five
are controls and pass on both.

## What it asserts

**A, four rows the ring keeps apart.** The daemon runs
`grouping_attributes = ["service.namespace", "k8s.namespace.name"]`, the
namespace second, so the screen has to find it behind another attribute. The
same n+1 on `shop-svc` is seeded under tenant-a, under tenant-b, with no
namespace, and under `service.namespace=commerce` with tenant-b behind it. The
ring has to hold them as four rows before any alert, or nothing below proves
anything.

**B, the freeze at reception.** One Alertmanager delivery carries three alerts
on the same service at the same instant: tenant-a, tenant-b and no namespace.
They are three incidents (`recorded=3`), since the namespace is part of the
id. Each tenant's incident holds its own rows and the unlabelled one, never
the other tenant's. The `commerce` row lands in tenant-b alone: a screen that
read only the first grouping attribute would leak it into tenant-a. The
incident without a namespace freezes by service, all four rows.

**C, the settle pass screens too.** Each tenant gets a new anti-pattern right
after the delivery, analysed after the reception freeze and inside the window.
After the settle each record grew by its own tenant's row and by nothing of
the other's. Both have to grow, so the absence of a foreign row cannot pass on
a settle that never ran.

**D, `findings=false`.** What the lab dashboard's Incidents table reads since
0.25.0, because the full listing sent up to 1000 findings per incident to a
table that shows their number. By page, by `namespace` and by `id`, each row
comes without `findings` and with `finding_count` equal to the full record's
length, every other field unchanged. `findings=maybe` and `offset=many` answer
401 without the key and 400 with it: the key is judged first, where a
malformed `offset` answered 400 ahead of it before 0.25.0.

**E, the archive.** Every NDJSON record of the tenant-a incident, the
reception one and the settle one, holds no row from another namespace.

**F, the startup warning.** `[daemon.incidents]` enabled without
`k8s.namespace.name` among `grouping_attributes` logs a warning and the daemon
serves. The config of legs A to E, which has the namespace second, does not
warn. Under `["tenant.id"]` the ingest keeps no namespace attribute, so a
tenant-b trace lands in a tenant-a incident: the freeze by service the warning
announces.

## What it does not assert

Incidents recorded before an upgrade keep what they froze. That is the
absence of a migration, not a behaviour to exercise. The Hub side is
`hub-incidents-mirror`'s: the Hub copies what the daemon froze, so the screen
reaches it without a change of its own.
