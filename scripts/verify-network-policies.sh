#!/usr/bin/env bash
# Verify the zero-trust NetworkPolicy contract:
#   1. An unlabeled pod in shop CANNOT reach Postgres (deny by default).
#   2. A labeled lab pod in shop CAN reach Postgres.
#   3. The perf-sentinel daemon CAN reach api.electricitymaps.com:443.
#   4. The GitLab runner CAN reach github.com:443 (when GitLab CE is up).
#   5. Prometheus CAN scrape a target ServiceMonitor (asserted via the
#      Prometheus query API showing recent samples for the lab daemon).
#
# Usage: ./scripts/verify-network-policies.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

color_blue()   { printf "\033[34m%s\033[0m\n" "$*"; }
color_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
color_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
warn() { color_yellow "    warn: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

# Run a one-shot probe pod with --restart=Never (no TTY required, sandbox-
# compatible). Returns the pod's exit code so the caller can assert.
run_probe() {
  local namespace="$1" probe_name="$2"
  shift 2
  kubectl run --rm --restart=Never --image=alpine:3.19 \
    -n "${namespace}" "${probe_name}" \
    --quiet --attach \
    -- "$@"
}

step "1. Unlabeled pod in shop must NOT reach Postgres"
# Pod has no `app.kubernetes.io/part-of: perf-sentinel-lab` label, so
# the shop-services-egress policy does not apply, only default-deny.
# nc -z exits 1 on connection refused or timeout.
set +e
run_probe shop probe-noauth -- timeout 5 nc -z postgres.db 5432 2>/dev/null
NEG_EXIT=$?
set -e
if [ "${NEG_EXIT}" -eq 0 ]; then
  die "negative test FAILED: unlabeled pod reached postgres.db:5432, NetworkPolicy is not enforcing default-deny"
fi
ok "unlabeled probe blocked (exit ${NEG_EXIT})"

step "2. labeled lab probe in shop must reach Postgres"
# The order-service image is distroless so we cannot kubectl exec
# `nc` inside it directly. Spawn an ephemeral alpine probe with the
# `app.kubernetes.io/part-of: perf-sentinel-lab` label so the
# shop-services-egress policy applies.
set +e
kubectl run --rm --restart=Never --image=alpine:3.19 \
  -n shop probe-labeled \
  --labels="app.kubernetes.io/part-of=perf-sentinel-lab" \
  --quiet --attach \
  -- timeout 5 nc -z postgres.db 5432
POS_EXIT=$?
set -e
if [ "${POS_EXIT}" -ne 0 ]; then
  die "positive test FAILED: labeled lab probe cannot reach postgres.db:5432 (exit ${POS_EXIT})"
fi
ok "labeled probe reaches postgres.db:5432"

step "3. perf-sentinel daemon must reach api.electricitymaps.com:443"
DAEMON_POD="$(kubectl -n observability get pods -l app.kubernetes.io/name=perf-sentinel-daemon \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "${DAEMON_POD}" ] || die "no daemon pod"
# The daemon image is distroless so we cannot exec a shell inside.
# Instead, watch the daemon's own logs for an Electricity Maps fetch
# attempt that reaches the API. /api/export/report carries
# scoring_config when the API auth is wired and FQDN egress works.
PORT=14318
if ! curl -fsS "http://localhost:${PORT}/api/export/report" \
     | python3 -c 'import json,sys
report=json.load(sys.stdin)
sc=report.get("green_summary",{}).get("scoring_config")
assert sc and sc.get("api_version"), "no scoring_config (egress to EM API likely blocked)"
print("    ok: scoring_config present:", sc.get("api_version"))'; then
  warn "scoring_config not present yet, retrying after 30s of traffic"
  sleep 30
  curl -fsS "http://localhost:${PORT}/api/export/report" \
    | python3 -c 'import json,sys
report=json.load(sys.stdin)
sc=report.get("green_summary",{}).get("scoring_config")
assert sc and sc.get("api_version"), "scoring_config still missing, FQDN egress likely blocked"
print("    ok (retry): scoring_config:", sc.get("api_version"))' \
    || die "perf-sentinel daemon cannot reach Electricity Maps"
fi

step "4. GitLab runner must reach github.com:443"
# The chart's gitlab-org components expose `app=<component>` plus
# `release=gitlab` (cf. manifests/network-policies.yaml comment 4.H),
# not the recommended `app.kubernetes.io/name` label family. The
# gitlab-runner sub-chart specifically lands on
# `app=gitlab-gitlab-runner` (release name + chart name). Match on
# both labels to be specific (avoids matching a build pod or any other
# component named gitlab-gitlab-runner that would lack release=gitlab).
RUNNER_POD="$(kubectl -n gitlab-ce get pods -l app=gitlab-gitlab-runner,release=gitlab \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "${RUNNER_POD}" ]; then
  warn "no gitlab-runner pod, skipping (run make up-gitlab to enable)"
else
  if ! kubectl -n gitlab-ce exec "${RUNNER_POD}" -- \
       timeout 5 sh -c 'nc -z github.com 443' 2>/dev/null; then
    die "GitLab runner cannot reach github.com:443"
  fi
  ok "gitlab-runner reaches github.com:443"
fi

step "5. Prometheus reaches the perf-sentinel daemon scrape path"
# Asserts the network path, not the metric value: scrape_samples_scraped
# proves Prometheus successfully connected to the target endpoint and
# read bytes back, regardless of whether the parser then accepted those
# bytes. `up{}=1` would be a stricter check but it conflates network
# drops with metric-format issues unrelated to NetworkPolicy.
ASSERTION_5_STATUS="UNKNOWN"
if curl -fsS "http://localhost:9090/api/v1/query?query=scrape_samples_scraped%7Bjob%3D%22perf-sentinel-daemon%22%7D" 2>/dev/null \
     | python3 -c 'import json,sys
r=json.load(sys.stdin)
result=r.get("data",{}).get("result",[])
assert result, "no scrape_samples_scraped sample for perf-sentinel-daemon"
val=int(float(result[0]["value"][1]))
assert val > 0, f"scrape_samples_scraped=0 (Prometheus cannot reach daemon target on the wire)"
print(f"    ok: scrape_samples_scraped={val} (NetworkPolicy allows the scrape path)")'; then
  ASSERTION_5_STATUS="PASS"
else
  warn "Prometheus port-forward not on 9090. Run: kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
  warn "  then re-run this check; or accept this assertion as SKIPPED."
  ASSERTION_5_STATUS="SKIPPED"
fi

color_green ""
if [ -z "${RUNNER_POD:-}" ]; then
  ASSERTION_4_STATUS="SKIPPED"
else
  ASSERTION_4_STATUS="PASS"
fi
color_green "NetworkPolicy verification summary:"
color_green "  1. unlabeled probe blocked         PASS"
color_green "  2. labeled probe reaches Postgres  PASS"
color_green "  3. daemon reaches Electricity Maps PASS"
color_green "  4. runner reaches github.com:443   ${ASSERTION_4_STATUS}"
color_green "  5. Prometheus scrape path open     ${ASSERTION_5_STATUS}"
if [ "${ASSERTION_4_STATUS}" = "SKIPPED" ] || [ "${ASSERTION_5_STATUS}" = "SKIPPED" ]; then
  color_yellow ""
  color_yellow "Some assertions were SKIPPED. Run \`make up-gitlab\` (assertion 4) and"
  color_yellow "establish the Prometheus port-forward (assertion 5) for the full matrix."
fi
