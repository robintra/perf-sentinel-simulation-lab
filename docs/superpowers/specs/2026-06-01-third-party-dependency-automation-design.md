# Third-party dependency automation (Renovate) + immediate bumps

- Date: 2026-06-01
- Status: approved (design), pending implementation
- Scope: simulation lab repo only. Custom service **application** dependencies are out of scope.

## Problem

Dependency hygiene in the lab is half-wired and inconsistent:

- **Dependabot is live** (`.github/dependabot.yml`): tracks `github-actions` and `docker` under `/services/shared-dockerfile`. Proven (PRs #6, #7 merged).
- **Renovate is dead config**: `renovate.json` exists at the repo root but the Renovate GitHub App is **not installed** (no Renovate PRs, no Dependency Dashboard issue). Its custom regex manager also only covers 3 of the ~8 shell-pinned versions and references nothing for Cilium/calico/k3d/helm.
- The lab's most important third-party versions are pinned in **shell scripts** and bumped manually, tracked by nothing live:
  - `scripts/bootstrap.sh`: `KPS_CHART_VERSION=84.4.0`, `OTEL_CHART_VERSION=0.153.0`, `TEMPO_IMAGE_VERSION=2.10.5` (log string only).
  - `scripts/install-cni.sh`: `CILIUM_VERSION=1.19.3`, calico `tigera-operator --version v3.32.0`.
  - `scripts/hubble-ui.sh`: Cilium `--version 1.19.3` **hardcoded** (duplicate of `install-cni.sh` → drift).
  - workflows: `K3D_TAG=v5.8.3`, `azure/setup-helm` input `version: v3.18.4`.
- Third-party images in `manifests/*.yaml` and `helm/values/*.yaml` are digest-pinned with `# version` comments — Renovate's `kubernetes` / `helm-values` managers cover these once the app runs.
- Tempo is pinned in **two** places: the cosmetic log var in `bootstrap.sh` and the real digest in `manifests/tempo.yaml`.

## Decisions

1. **Tool**: Renovate (chosen). It is the only option that auto-PRs Helm chart and shell-pinned tool versions via custom regex managers.
2. **Majors held**: keep Tempo `2.10.5` and helm `v3.18.4`. Renovate surfaces `grafana/tempo` v3 and `helm/helm` v4 as **isolated, non-automerged major PRs** to review/test separately.
3. **One bot**: Renovate owns every ecosystem; **delete `.github/dependabot.yml`** to avoid duplicate PRs.
4. **services/ scope**: track third-party **base images** (Dockerfile `FROM`) only; **do not** open PRs on custom service application deps (npm / NuGet / Maven). Implemented by disabling those managers repo-wide, not by ignoring `services/` (which would also drop base-image tracking).
5. **perf-sentinel excluded**: `ghcr.io/robintra/perf-sentinel` is the product under test, bumped on release via `repository_dispatch` — Renovate must not touch it.

## Part A — Immediate manual bumps ("en attendant")

| Component                | File(s)                                                                           | From                | To            | Type           |
|--------------------------|-----------------------------------------------------------------------------------|---------------------|---------------|----------------|
| Cilium (chart+app)       | `scripts/install-cni.sh` (`CILIUM_VERSION`), `scripts/hubble-ui.sh` (`--version`) | 1.19.3              | 1.19.4        | patch          |
| kube-prometheus-stack    | `scripts/bootstrap.sh` (`KPS_CHART_VERSION`)                                      | 84.4.0              | 86.1.0        | 2 minors       |
| opentelemetry-collector  | `scripts/bootstrap.sh` (`OTEL_CHART_VERSION`)                                     | 0.153.0             | 0.158.0       | minor          |
| grafana/tempo            | —                                                                                 | 2.10.5              | (hold v3.0.0) | major — held   |
| helm (`setup-helm`)      | —                                                                                 | v3.18.4             | (hold v4.2.0) | major — held   |
| k3d                      | —                                                                                 | v5.8.3              | —             | already latest |
| calico (tigera-operator) | —                                                                                 | v3.32.0             | —             | already latest |
| kubectl                  | —                                                                                 | `latest` (floating) | —             | n/a            |

Cilium is bumped in **both** files (kills the duplicate-drift). KPS 84→86 may carry values/CRD changes; the fresh-install lab run is the validation gate (`helm upgrade --install --wait` fails loudly if values are incompatible).

## Part B — Renovate configuration (`renovate.json` rewrite)

- **Base**: `config:recommended` + `:semanticCommits` + `:maintainLockFilesWeekly`. Schedule `before 6am on monday` (Europe/Paris), label `dependencies`, commit prefix `chore(deps)`, Dependency Dashboard on.
- **Native managers** (already cover, keep): `github-actions` (action SHAs), `dockerfile` (base images), `kubernetes` (`manifests/*.yaml` digests + comments), `helm-values` (`helm/values/*.yaml`).
- **customManagers (regex)** for shell/workflow pins, with explicit datasources:
  - `scripts/bootstrap.sh`: `KPS_CHART_VERSION` → datasource `helm`, dep `kube-prometheus-stack`, registry `https://prometheus-community.github.io/helm-charts`; `OTEL_CHART_VERSION` → `helm`, `opentelemetry-collector`, `https://open-telemetry.github.io/opentelemetry-helm-charts`. (Do **not** manage `TEMPO_IMAGE_VERSION` here — Tempo is tracked via the manifest digest to avoid dup PRs; the log var is cosmetic.)
  - `scripts/install-cni.sh`: `CILIUM_VERSION` → `helm`, `cilium`, `https://helm.cilium.io`; calico `--version` → `helm`, `tigera-operator`, `https://docs.tigera.io/calico/charts`.
  - `scripts/hubble-ui.sh`: Cilium `--version` → `helm`, `cilium`, `https://helm.cilium.io`.
  - `.github/workflows/*.yml`: `K3D_TAG` → `github-tags`, `k3d-io/k3d`; `setup-helm` `version:` input → `github-releases`, `helm/helm`.
- **packageRules**:
  - Group `helm` + `helm-values` chart updates → "observability charts".
  - Group cluster tooling (k3d, helm, kubectl, cilium, tigera-operator) → "cluster tooling".
  - Major updates for `grafana/tempo` and `helm/helm`: separate PR, `automerge: false`, label `major-review`.
  - Keep: no `major` on `kubernetes`-managed workload images.
  - Disable `npm`, `nuget`, `gradle`, `maven`, `gomod`, `pip_requirements`, `poetry` managers (custom service app deps out of scope).
  - Disable updates for `ghcr.io/robintra/perf-sentinel`.

## Part C — Cleanup

- Delete `.github/dependabot.yml`.
- Dedupe Cilium version (bump both `install-cni.sh` and `hubble-ui.sh`); note the standing drift risk in a comment.

## Part D — Out-of-band (Robin)

- Install the **Renovate GitHub App** on `robintra/perf-sentinel-simulation-lab` (cannot be done from CLI).
- Optional: add a `renovate-config-validator` step in CI to lint `renovate.json` on PRs.

## Validation

- `renovate-config-validator renovate.json` (run locally via `npx`) must pass.
- `bash -n` on every edited script.
- The next lab validation run (`validate-on-release.yml`, `latest`) exercises the bumped KPS/OTel/Cilium end-to-end.

## Risks

- KPS 84→86 values/CRD compatibility — gated by the lab run; rollback = revert the one-line bump.
- Held majors (Tempo v3, helm v4) will appear as recurring Renovate PRs until reviewed; the `major-review` label and isolated PRs make that explicit, not silent.
