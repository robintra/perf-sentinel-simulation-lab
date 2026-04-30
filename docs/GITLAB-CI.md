# GitLab CE in-cluster, end-to-end validation of the perf-sentinel template

The lab embeds a GitLab Community Edition release in the `gitlab-ce`
namespace so the published perf-sentinel CI template (upstream at
`docs/ci-templates/gitlab-ci.yml`) can be exercised against a real
self-hosted GitLab without leaving the cluster.

## What this validates

`make verify-gitlab-perf-sentinel` runs two pipelines and asserts:

1. **Default branch behaviour**: a push to `main` triggers the
   `perf-sentinel` job. The pipeline ends in `success` because the
   template marks the gate `allow_failure: true` on `main` (the gate
   should not block trunk).
2. **Merge request behaviour**: a push to `feat/test-mr` plus an
   opened MR triggers the same job under
   `merge_request_event`. The pipeline ends in `failed` because the
   gate is enforced (`allow_failure: false`) and the test fixture is
   calibrated to breach the configured thresholds.
3. **Artefact contract**: the SARIF file is valid v2.1.0, the JSON
   report carries `findings`, `green_summary`, and `quality_gate`,
   and the GitLab Code Quality JSON is a non-empty array, even on
   the failed MR pipeline (artifact `when: always`).
4. **Free-tier Pages publishing**: the `perf-sentinel-pages-simple`
   job runs on `main` and produces `public/index.html`. The lab does
   not assert HTTP fetches via `${CI_PAGES_URL}` because the
   in-cluster GitLab CE has no Ingress (see Limitations).

## The fixture

The test project consumes a static fixture set under
`artifacts/fixtures/`:

- `em-real-time-traces.json` was captured against a daemon configured
  with the Electricity Maps sandbox key, so the analyzed report carries
  `green_summary.co2.total.model = "electricity_maps_api"`. It is
  re-captured by `scripts/capture-trace-fixture.sh` after `make up`,
  `make seed-services`, `make seed-electricity-maps`,
  `make validate-findings`. The script queries the lab's Tempo, fetches
  raw OTLP-JSON traces, converts them to Jaeger format, and validates
  the result with `perf-sentinel analyze --input`. Re-capture after
  every daemon-image bump or after major detector changes upstream so
  the verify keeps exercising the current code path. The fixture grows
  with each capture as the lab adds resource attributes (the 0.5.14
  capture is around 7 MiB, vs around 1 MiB before the cloud.region tag
  rollout). If the fixture exceeds 20 MiB or git pack growth becomes a
  concern, consider lowering `LIMIT_PER_SERVICE` in
  `scripts/capture-trace-fixture.sh` or moving the fixture to Git LFS.
- `perf-sentinel-test.toml` is calibrated with strict thresholds so the
  fixture trips `analyze --ci` (exit 1) and the MR pipeline observes a
  failed quality gate.
- `gitlab-ci-from-upstream.yml` is a copy of
  `docs/ci-templates/gitlab-ci.yml` from the perf-sentinel repo with
  the version pin bumped, the `dependencies:` line decommented, and a
  factice `integration-tests` job added that republishes the trace
  fixture as an artefact for the next stage.

## Install

```bash
make up-gitlab               # ~10 min, helm install + port-forward
make seed-gitlab-project     # creates perf-sentinel-template-test, pushes initial fixture
make verify-gitlab-perf-sentinel
```

`make up-gitlab` pins the chart version (currently `9.11.2`,
app `v18.11.2`) and applies `helm/values/gitlab-ce.yaml`. It opens a
background port-forward to `localhost:8181`.

## Access the UI

```bash
kubectl -n gitlab-ce get secret gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Open `http://localhost:8181` and log in as `root` with that password.

## Limitations

- **No Ingress, no DNS**. Access is via `kubectl port-forward` on
  `8181` (workhorse port). This is enough for the API, the Web UI, and the runner,
  but Pages serving via `${CI_PAGES_URL}` is best-effort: the
  rendered HTML lives in the artefact `public/index.html` and can
  be opened locally rather than fetched over HTTP.
- **No multi-deployment Pages** (Premium-only feature). The fixture
  uses the Free-tier `perf-sentinel-pages-simple` job and leaves the
  Premium `path_prefix` block commented out.
- **No container registry**. The template pulls perf-sentinel
  binaries from GitHub Releases, so the runner needs egress to
  `github.com`.
- **No SSO**. Root login only.
- **Runner uses the Kubernetes executor**. No Docker-in-Docker, no
  shell executor.

## Reset

```bash
make down-gitlab
make up-gitlab
make seed-gitlab-project
make verify-gitlab-perf-sentinel
```

Useful after a CNI migration or any teardown of the k3d cluster.
GitLab data is not persisted across resets: each `up-gitlab` starts
from a clean PVC set and re-bootstraps the project.

## Troubleshooting

### `make up-gitlab` times out waiting for the API

The chart `--wait` flag covers pods Ready, not the application's HTTP
readiness. Postgres init plus Sidekiq warmup can take several minutes
on first boot. Check:

```bash
kubectl -n gitlab-ce get pods
kubectl -n gitlab-ce logs deploy/gitlab-webservice-default --tail=200
```

If pods are Running but the API never came up, the port-forward may
have died. Re-run `make up-gitlab` (it stops any previous
port-forward and re-establishes one).

### `make seed-gitlab-project` fails on token acquisition

The script logs in via OAuth2 password grant against
`/oauth/token`. Common causes:

- The initial root password Secret hasn't been created yet (chart
  install is still in progress). Wait for `make up-gitlab` to
  return.
- The port-forward died. Check `cat /tmp/gitlab-port-forward.log`
  and restart `make up-gitlab` if needed.

### `make verify-gitlab-perf-sentinel` fails because no pipeline picks up the SHA

The runner takes a moment to register after a fresh chart install.
The first pipeline can sit in `pending` for 30-60 seconds. The verify
script polls for 600 s before giving up. If it times out:

```bash
kubectl -n gitlab-ce get pods -l app.kubernetes.io/name=gitlab-runner
kubectl -n gitlab-ce logs deploy/gitlab-gitlab-runner --tail=200
```

### The Pages job runs but `${CI_PAGES_URL}` returns 404

Expected on this lab setup (no Ingress). The verify script does not
assert Pages over HTTP. To inspect the rendered HTML, download the
artefact:

```bash
TOKEN="$(cat /tmp/gitlab-pat.txt)"
PROJECT_ID="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  http://localhost:8181/api/v4/projects?owned=true \
  | python3 -c 'import json,sys; print([p for p in json.load(sys.stdin) if p["path"]=="perf-sentinel-template-test"][0]["id"])')"
curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  "http://localhost:8181/api/v4/projects/${PROJECT_ID}/jobs/<pages-job-id>/artifacts" \
  -o pages.zip
unzip pages.zip && open public/index.html
```
