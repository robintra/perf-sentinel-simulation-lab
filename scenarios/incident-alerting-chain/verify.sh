#!/usr/bin/env bash
# The alerting half of POST /api/incidents (perf-sentinel 0.22.0).
#
# 0.20.0 gave the daemon an incident intake, and `incident-window-capture`
# proves what it does with a delivery. Nothing proved where the delivery comes
# from: both incident scenarios hand-build the Alertmanager envelope in python,
# and docs/SCENARIOS.md said so in as many words, "Deliberately not asserted:
# ... Alertmanager itself". 0.22.0 ships that half as two example files, plus
# the bearer credential they need because neither operator's CRD can send an
# arbitrary header. This scenario is that gap closed.
#
# Legs, in order of what they cost:
#
#   A. Both example files parse and promtool accepts their rules.
#   B. The two files carry the SAME five rules, the four alerts and the
#      recording rule they subtract. Everything proved on one is then proved on
#      its twin, which is what lets leg C run once.
#   C. promtool test rules over synthetic kube-state-metrics series: the nine
#      behaviours the files claim in prose but cannot demonstrate, including
#      the two duplicated-series joins, the rule that goes silent when a
#      container carries no memory limit, and both directions of the record,
#      the untraced workload it drops and the service cap that makes it stop
#      dropping anything.
#   D. The CRD fields the receiver uses exist in the schema that admits it,
#      read from the installed CRD when there is a cluster and from the pinned
#      chart otherwise.
#   E. The VictoriaMetrics twin is in VM's own spelling. The real mistake on a
#      hand-maintained twin is a camelCase key copied across, and no schema
#      available here would catch it.
#   F. kubeconform, recorded as the SKIP it is: with no CRD schema it skips all
#      four resources and exits 0, which is the perfect false PASS.
#   G. A 0.21.0 twin beside the daemon under test, sharing its ConfigMap and
#      its Secret, so the only difference between them is the image. Plus the
#      guard that says they really are two versions: /api/status reports the
#      same number on both, because Cargo.toml still carries 0.21.0 on this
#      branch, so the 401 body is the discriminant.
#   H. The shipped rules applied unedited, against a kube-state-metrics scaled
#      to two, beside a copy of the deploy rule's pre-review expression. One
#      evaluates, the other does not, and both shipped groups are read: a
#      record that fails to evaluate is silent, it just stops suppressing.
#   I. The chain: the shipped rules applied unedited fire on real series, the
#      default namespace matcher swallows the delivery in complete silence,
#      disabling it lets a real Alertmanager post its bearer credential, and
#      the incident comes back with its window frozen. The twin refuses the
#      same delivery at the same instant.
#   J. The VictoriaMetrics twin in front of a real API server carrying that
#      operator's CRDs, installed without any controller so nothing
#      reconciles them. Reports what the schema says about http_config, which
#      is what decides whether the "an older API server prunes the block"
#      claim is even a possible mechanism.
#
# Needs: python3 + PyYAML. promtool and kubeconform legs SKIP when absent, the
# cluster legs SKIP without a cluster, and every SKIP is counted in the
# summary, because a skipped leg reads exactly like a passing one otherwise.
#
# The cluster legs mutate shared state: Alertmanager's matcher strategy and the
# kube-state-metrics replica count. Both are restored by a trap, and the
# pre-flight puts the replica count back before it starts, so an interrupted
# run does not poison the scenarios after it.

set -uo pipefail

SCENARIO="incident-alerting-chain"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="${SCENARIO_DIR}/fixtures"
LAB_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
EXAMPLES_DIR="${PERF_SENTINEL_REPO_PATH}/examples"
PROM_FILE="${EXAMPLES_DIR}/incident-alerts-prometheus-operator.yaml"
VM_FILE="${EXAMPLES_DIR}/incident-alerts-victoriametrics-operator.yaml"

rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
color_yell()  { printf "\033[33m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
skip() { color_yell  "    skip: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# ---------------------------------------------------------------------------
step "0. Pre-flight"
command -v python3 >/dev/null || die "python3 not on PATH"
python3 -c 'import yaml' 2>/dev/null || die "python3 PyYAML not installed"
[ -f "${PROM_FILE}" ] || die "no example at ${PROM_FILE} (set PERF_SENTINEL_REPO_PATH)"
[ -f "${VM_FILE}" ] || die "no example at ${VM_FILE}"
ok "examples found under ${EXAMPLES_DIR}"

python3 "${FIXTURES}/extract_rules.py" "${PROM_FILE}" "${TMP_DIR}/rules.yaml" PrometheusRule \
  || die "could not extract the PrometheusRule groups"
python3 "${FIXTURES}/extract_rules.py" "${VM_FILE}" "${TMP_DIR}/vm-rules.yaml" VMRule \
  || die "could not extract the VMRule groups"
ok "rule groups extracted from both files"

# ---------------------------------------------------------------------------
step "A. promtool accepts the rules of both files"
if ! command -v promtool >/dev/null; then
  skip "promtool not installed"
  record "promtool check" SKIP "promtool absent"
else
  A_OK=1
  for f in rules.yaml vm-rules.yaml; do
    if A_OUT="$(promtool check rules "${TMP_DIR}/${f}" 2>&1)"; then
      ok "${f}: $(printf '%s' "${A_OUT}" | grep -i -m1 success | sed 's/^ *//')"
    else
      fail "${f}: ${A_OUT}"
      A_OK=0
    fi
  done
  if [ "${A_OK}" = "1" ]; then
    record "promtool check" PASS "both rule sets accepted, 5 rules each"
  else
    record "promtool check" FAIL "see log"
  fi
fi

# ---------------------------------------------------------------------------
step "B. The two files carry the same five rules"
if B_OUT="$(python3 "${FIXTURES}/check_twins.py" "${TMP_DIR}/rules.yaml" "${TMP_DIR}/vm-rules.yaml" 2>&1)"; then
  ok "${B_OUT}"
  record "twins identical" PASS "${B_OUT}"
else
  fail "${B_OUT}"
  record "twins identical" FAIL "${B_OUT}"
fi

# ---------------------------------------------------------------------------
step "C. The five rules behave the way the file describes them"
# The nine cases live in fixtures/rules-unit-tests.yaml. They settle
# deterministically, in under a second, what a cluster settles slowly and only
# with a second kube-state-metrics: the two duplicated-series joins, the rule
# that is silent without a memory limit, the pod shape that loses its service
# label, and the recording rule both ways, dropping a workload the daemon never
# ingested and dropping nobody once the service cap has overflowed. Every case
# gives the record a left-hand side to subtract from, so a rule that fires
# fires past the record rather than for want of anything to subtract. Cheap
# enough to run on every pass, and they fail on their own.
if ! command -v promtool >/dev/null; then
  skip "promtool not installed"
  record "rule unit tests" SKIP "promtool absent"
else
  cp "${FIXTURES}/rules-unit-tests.yaml" "${TMP_DIR}/tests.yaml"
  if C_OUT="$(cd "${TMP_DIR}" && promtool test rules tests.yaml 2>&1)"; then
    ok "9 behaviours asserted: the oom/restart exclusion, the for clause, the"
    ok "rule that stays silent with no memory limit, both duplicated-series"
    ok "joins, the pod shape that loses its service label, the workload the"
    ok "daemon never ingested, and the service cap that silences nobody"
    record "rule unit tests" PASS "promtool test rules SUCCESS, 9 cases"
  else
    fail "promtool test rules failed:"
    printf '%s\n' "${C_OUT}" | head -20
    record "rule unit tests" FAIL "see log"
  fi
fi

# ---------------------------------------------------------------------------
step "D. The receiver's CRD fields exist in the schema that admits it"
CRD_SRC=""
if kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o json \
     > "${TMP_DIR}/crd-amc.json" 2>/dev/null; then
  CRD_SRC="the cluster"
elif command -v helm >/dev/null; then
  KPS_VERSION="$(awk -F'"' '/^KPS_CHART_VERSION=/ {print $2}' "${LAB_ROOT}/scripts/bootstrap.sh")"
  if [ -n "${KPS_VERSION}" ] && helm pull prometheus-community/kube-prometheus-stack \
       --version "${KPS_VERSION}" --untar -d "${TMP_DIR}/chart" >/dev/null 2>&1; then
    CRD_YAML="${TMP_DIR}/chart/kube-prometheus-stack/charts/crds/crds/crd-alertmanagerconfigs.yaml"
    if python3 -c "import json,sys,yaml; json.dump(yaml.safe_load(open(sys.argv[1])), open(sys.argv[2],'w'))" \
         "${CRD_YAML}" "${TMP_DIR}/crd-amc.json" 2>/dev/null; then
      CRD_SRC="chart ${KPS_VERSION}"
    fi
  fi
fi

if [ -z "${CRD_SRC}" ]; then
  skip "no AlertmanagerConfig CRD reachable, from the cluster or from the chart"
  record "CRD fields" SKIP "no CRD source"
elif D_OUT="$(python3 "${FIXTURES}/check_crd_fields.py" "${TMP_DIR}/crd-amc.json" 2>&1)"; then
  ok "from ${CRD_SRC}: ${D_OUT}"
  record "CRD fields" PASS "${CRD_SRC}: bearer path present, no arbitrary-header field"
else
  fail "${D_OUT}"
  record "CRD fields" FAIL "${D_OUT}"
fi

# ---------------------------------------------------------------------------
step "E. The VictoriaMetrics twin is written in VictoriaMetrics' own spelling"
if E_OUT="$(python3 "${FIXTURES}/check_vm_spelling.py" "${VM_FILE}" 2>&1)"; then
  ok "${E_OUT}"
  record "VM spelling" PASS "${E_OUT}"
else
  fail "${E_OUT}"
  record "VM spelling" FAIL "${E_OUT}"
fi

# ---------------------------------------------------------------------------
step "F. kubeconform, and what it does not say"
# Recorded as the SKIP it is. With no CRD schema to resolve, kubeconform marks
# all four resources Skipped and exits 0. Banking that as a PASS would be the
# perfect false green: a scenario reporting success for a tool that validated
# nothing at all. Leg D is what actually reads the schema.
if ! command -v kubeconform >/dev/null; then
  skip "kubeconform not installed"
  record "kubeconform" SKIP "kubeconform absent"
else
  F_SKIPPED=0
  F_INVALID=0
  for f in "${PROM_FILE}" "${VM_FILE}"; do
    F_OUT="$(kubeconform -strict -ignore-missing-schemas -summary "$f" 2>&1 | tail -1)"
    n="$(printf '%s' "${F_OUT}" | sed -n 's/.*Skipped: \([0-9]*\).*/\1/p')"
    i="$(printf '%s' "${F_OUT}" | sed -n 's/.*Invalid: \([0-9]*\).*/\1/p')"
    F_SKIPPED=$(( F_SKIPPED + ${n:-0} ))
    F_INVALID=$(( F_INVALID + ${i:-0} ))
  done
  if [ "${F_INVALID}" != "0" ]; then
    fail "kubeconform reports ${F_INVALID} invalid resource(s)"
    record "kubeconform" FAIL "Invalid=${F_INVALID}"
  elif [ "${F_SKIPPED}" = "4" ]; then
    skip "all 4 resources Skipped for want of a CRD schema, so this proves nothing"
    record "kubeconform" SKIP "4/4 Skipped, leg D is what checks the schema"
  else
    ok "kubeconform validated $(( 4 - F_SKIPPED )) of 4 resources, none invalid"
    record "kubeconform" PASS "Skipped=${F_SKIPPED}, Invalid=0"
  fi
fi


# ===========================================================================
# Cluster legs. Everything above runs anywhere; what follows needs `make up`,
# a daemon under test seeded with `make seed-daemon-local`, and the tracegen
# image from `make seed-tracegen`.
# ===========================================================================
NS="observability"
VICTIM_NS="incident-lab"
AM_POD="alertmanager-kube-prometheus-stack-alertmanager-0"
AM_CR="kube-prometheus-stack-alertmanager"
KSM="deploy/kube-prometheus-stack-kube-state-metrics"
DAEMON_URL="${DAEMON_URL:-http://127.0.0.1:14318}"
TWIN_PORT="${TWIN_PORT:-24318}"
PROM_PORT="${PROM_PORT:-19090}"
AM_PORT="${AM_PORT:-19093}"
AM_URL="http://127.0.0.1:${AM_PORT}"
TWIN_URL="http://127.0.0.1:${TWIN_PORT}"
PROM_URL="http://127.0.0.1:${PROM_PORT}"
CLUSTER_OK=0
declare -a FORWARD_PIDS=()

cluster_cleanup() {
  [ "${CLUSTER_OK}" = "1" ] || return 0
  step "Restoring the cluster"
  # Every restoration is idempotent and each one is attempted even if an
  # earlier one fails: a half-restored lab poisons every scenario after this
  # one, and the most expensive of those failures is silent.
  kubectl -n "${NS}" patch alertmanager "${AM_CR}" --type=merge \
    -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"OnNamespace"}}}' >/dev/null 2>&1 || true
  kubectl -n "${NS}" scale "${KSM}" --replicas=1 >/dev/null 2>&1 || true
  kubectl delete -f "${SCENARIO_DIR}/control-unaggregated-rule.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete prometheusrule perf-sentinel-incidents --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete alertmanagerconfig perf-sentinel-incidents --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete secret perf-sentinel-incidents-key --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS}" delete job tracegen-psbearer --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f "${SCENARIO_DIR}/manifests.yaml" --ignore-not-found >/dev/null 2>&1 || true
  for pid in "${FORWARD_PIDS[@]:-}"; do [ -n "${pid}" ] && kill "${pid}" 2>/dev/null; done
  ok "matcher strategy, kube-state-metrics replicas and every fixture removed"
}
trap cluster_cleanup EXIT

forward() {  # $1 = service, $2 = local port, $3 = remote port
  kubectl -n "${NS}" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  FORWARD_PIDS+=("$!")
}

incidents_count() {  # $1 = base url
  curl -s -H "X-API-Key: ${WRITE_KEY}" "$1/api/incidents" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "err"
}

unauth_count() {  # $1 = base url
  curl -s "$1/metrics" 2>/dev/null \
    | awk '/^perf_sentinel_incidents_rejected_total\{reason="unauthorized"\}/ {print $2; f=1} END {if (!f) print 0}'
}

promq() {  # $1 = PromQL, prints one JSON result array
  curl -s --get "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null
}

rule_fails() {  # $@ = rule group names, prints their total failures
  # A group Prometheus never loaded publishes no counter at all, and reading
  # that as zero is how a rule that is not there passes for a rule that
  # evaluates cleanly. Missing is reported as `absent`, never as a number.
  promq 'prometheus_rule_evaluation_failures_total' \
    | python3 -c "
import json, sys
seen = {}
for s in json.load(sys.stdin)['data']['result']:
    seen[s['metric'].get('rule_group', '').rsplit(';', 1)[-1]] = float(s['value'][1])
missing = [g for g in sys.argv[1:] if g not in seen]
print('absent(%s)' % ','.join(missing) if missing else int(sum(seen[g] for g in sys.argv[1:])))" \
    "$@" 2>/dev/null
}

route_target() {
  kubectl -n "${NS}" exec "${AM_POD}" -c alertmanager -- amtool config routes test \
    --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml \
    alertname=PerfSentinelOomKill perf_sentinel_kind=oom_kill \
    "namespace=${VICTIM_NS}" service=psbearer-probe-0000 severity=info 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
step "G. Pre-flight for the cluster legs, and the guard against an A/A"
if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  skip "no cluster reachable, every cluster leg is skipped"
  record "cluster chain" SKIP "no cluster"
elif ! kubectl -n "${NS}" get deploy perf-sentinel-daemon >/dev/null 2>&1; then
  skip "no perf-sentinel daemon deployed"
  record "cluster chain" SKIP "no daemon"
else
  UNDER_TEST_IMAGE="$(kubectl -n "${NS}" get deploy perf-sentinel-daemon \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  WRITE_KEY="$(kubectl -n "${NS}" get secret perf-sentinel-api-keys \
    -o jsonpath='{.data.incidents-api-key}' 2>/dev/null | base64 -d)"
  [ -n "${WRITE_KEY}" ] || die "no incidents-api-key in the perf-sentinel-api-keys Secret"

  # Reachability first, and on its own. Without this check a dead port-forward
  # reads as HTTP 000 in the matrix below, and the scenario would blame the
  # binary under test for a tunnel that is simply not up.
  curl -sf -o /dev/null "${DAEMON_URL}/api/status" \
    || die "${DAEMON_URL} is not answering. Run: scripts/port-forward.sh start"

  # Put the shared state back to its defaults before starting, so an earlier
  # run killed between its legs cannot make leg I assert the opposite of what
  # it means to. Both of these are what the trap restores on the way out.
  kubectl -n "${NS}" scale "${KSM}" --replicas=1 >/dev/null 2>&1
  kubectl -n "${NS}" patch alertmanager "${AM_CR}" --type=merge \
    -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"OnNamespace"}}}' >/dev/null 2>&1
  kubectl apply -f "${SCENARIO_DIR}/manifests.yaml" >/dev/null 2>&1 \
    || die "could not apply the scenario fixtures"
  kubectl -n "${NS}" rollout status deploy/perf-sentinel-daemon-ab --timeout=180s >/dev/null 2>&1 \
    || die "the 0.21.0 twin did not come up"
  CLUSTER_OK=1

  forward perf-sentinel-daemon-ab "${TWIN_PORT}" 14318
  forward kube-prometheus-stack-prometheus "${PROM_PORT}" 9090
  forward kube-prometheus-stack-alertmanager "${AM_PORT}" 9093
  # Poll rather than sleep: a tunnel that is not up yet answers 000, which
  # reads exactly like a daemon refusing a credential, and the matrix below
  # would blame the wrong thing.
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "${TWIN_URL}/api/status" && break
    sleep 2
  done
  curl -sf -o /dev/null "${TWIN_URL}/api/status" \
    || die "the 0.21.0 twin is not answering on ${TWIN_URL}"

  # The main Service must not have adopted the twin. If it had, every OTLP
  # export and every scrape in the cluster would be split between two daemons,
  # and half the lab would go quietly wrong.
  EP="$(kubectl -n "${NS}" get endpoints perf-sentinel-daemon \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"

  # The discrimination matrix. /api/status reports 0.21.0 on BOTH pods, because
  # Cargo.toml still carries the previous version on this branch, so the
  # version is not a discriminant. The 401 body is.
  M_TEST_HDR="$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: ${WRITE_KEY}" "${DAEMON_URL}/api/incidents")"
  M_TEST_BEARER="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${WRITE_KEY}" "${DAEMON_URL}/api/incidents")"
  M_TWIN_HDR="$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: ${WRITE_KEY}" "${TWIN_URL}/api/incidents")"
  M_TWIN_BEARER="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${WRITE_KEY}" "${TWIN_URL}/api/incidents")"

  if [ "${EP}" != "1" ]; then
    fail "the perf-sentinel-daemon Service has ${EP} endpoints, the twin joined it"
    record "A/B instrumented" FAIL "Service has ${EP} endpoints"
    CLUSTER_OK=0
  elif [ "${M_TWIN_HDR}" != "200" ]; then
    fail "the twin refuses the header key (${M_TWIN_HDR}): it is not a live gated daemon,"
    fail "so its 401 on bearer would prove nothing"
    record "A/B instrumented" FAIL "twin X-API-Key ${M_TWIN_HDR}"
    CLUSTER_OK=0
  elif [ "${M_TEST_BEARER}" != "200" ]; then
    fail "the daemon under test refuses a bearer token (${M_TEST_BEARER}). Image is"
    fail "${UNDER_TEST_IMAGE}. Run: make seed-daemon-local"
    record "A/B instrumented" FAIL "under test bearer ${M_TEST_BEARER}"
    CLUSTER_OK=0
  elif [ "${M_TWIN_BEARER}" != "401" ]; then
    fail "the twin ACCEPTS a bearer token: both pods run the same image, and the"
    fail "A/B below would assert the opposite of the truth while staying green"
    record "A/B instrumented" FAIL "twin bearer ${M_TWIN_BEARER}, an A/A"
    CLUSTER_OK=0
  else
    ok "under test (${UNDER_TEST_IMAGE}): header 200, bearer 200"
    ok "twin (released 0.21.0): header 200, bearer 401. One variable, and the"
    ok "twin answering the header is what says its 401 is about the version"
    record "A/B instrumented" PASS "header 200/200, bearer 200/401, one Service endpoint"
  fi
fi

# ---------------------------------------------------------------------------
step "H. The deploy rule survives a replicated kube-state-metrics"
# The one review fix on this branch that changes behaviour rather than prose.
# Two kube-state-metrics replicas publish kube_replicaset_owner twice per
# (namespace, replicaset), and the unaggregated join then refuses the match:
# the rule does not alert late, it fails to evaluate and posts nothing, ever.
# Leg C proves the same thing offline; this proves it on real series.
#
# Both shipped groups are read, not just the alerting one. The record of the
# untraced-services group is the only expression in either file joining on an
# aggregated scalar, and a group that fails to evaluate leaves the record
# empty, which is silent: every alert then passes the `unless` and leg I below
# reports the same alerts it reports when all is well.
if [ "${CLUSTER_OK}" != "1" ]; then
  skip "no usable cluster"
  record "group_left fix" SKIP "no cluster"
else
  # The rules go in BYTE FOR BYTE. No container selector is substituted, no
  # regex adapted: the victim in manifests.yaml names its container `app`
  # precisely so the shipped file applies unedited. Validating an adapted copy
  # would validate the copy. They are applied here rather than in leg I so
  # this leg has something of theirs to read.
  python3 "${FIXTURES}/extract_doc.py" "${PROM_FILE}" PrometheusRule "${TMP_DIR}/rule.yaml" \
    || die "could not extract the PrometheusRule document"
  kubectl apply -f "${TMP_DIR}/rule.yaml" >/dev/null 2>&1 \
    || die "the API server refused the shipped PrometheusRule"
  kubectl -n "${NS}" scale "${KSM}" --replicas=2 >/dev/null 2>&1
  kubectl apply -f "${SCENARIO_DIR}/control-unaggregated-rule.yaml" >/dev/null 2>&1
  kubectl -n "${NS}" rollout status "${KSM}" --timeout=180s >/dev/null 2>&1
  # Three evaluation cycles, so a failure has had time to be counted.
  sleep 100

  DUPES="$(promq 'count(count by (replicaset) (kube_replicaset_owner{owner_kind="Deployment"}) > 1)' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)"
  SHIPPED_FAILS="$(rule_fails perf-sentinel-incidents perf-sentinel-untraced-services)"
  CONTROL_FAILS="$(rule_fails perf-sentinel-incidents-control)"

  if [ "${DUPES:-0}" -lt 1 ]; then
    fail "no replicaset has a duplicated owner series, so this leg tests nothing"
    record "group_left fix" FAIL "no duplication, kube-state-metrics may not have scaled"
  elif [[ "${SHIPPED_FAILS}" == absent* || "${CONTROL_FAILS}" == absent* ]]; then
    fail "a rule group never reached Prometheus: shipped=${SHIPPED_FAILS}, control=${CONTROL_FAILS}"
    fail "(a group it never loaded publishes no counter, which reads exactly"
    fail "like a group that evaluates cleanly)"
    record "group_left fix" FAIL "shipped=${SHIPPED_FAILS}, control=${CONTROL_FAILS}"
  elif [ "${SHIPPED_FAILS}" = "0" ] && [ "${CONTROL_FAILS}" != "0" ]; then
    ok "${DUPES} replicaset(s) carry a duplicated owner series"
    ok "both shipped groups evaluate cleanly (0 failures over the four alerts"
    ok "and the record), the pre-review one fails ${CONTROL_FAILS} times: not a"
    ok "late alert, an evaluation that never happens"
    record "group_left fix" PASS "shipped=0 failures over both groups, pre-review=${CONTROL_FAILS}, ${DUPES} duplicated series"
  else
    fail "shipped rule failures=${SHIPPED_FAILS}, pre-review control=${CONTROL_FAILS}"
    fail "(expected 0 and non-zero: either the fix regressed, or the control no"
    fail "longer reproduces the duplication it is there to reproduce)"
    record "group_left fix" FAIL "shipped=${SHIPPED_FAILS}, control=${CONTROL_FAILS}"
  fi
fi

# ---------------------------------------------------------------------------
step "I. The chain, from a real alert to a frozen window"
if [ "${CLUSTER_OK}" != "1" ]; then
  skip "no usable cluster"
  record "rules fire" SKIP "no cluster"
  record "namespace matcher" SKIP "no cluster"
  record "bearer delivers" SKIP "no cluster"
else
  # The shipped PrometheusRule went in unedited in leg H and is still applied.
  #
  # The receiver needs three substitutions and the scenario names each one:
  # two are addresses (this lab calls its Service perf-sentinel-daemon and
  # exposes it on 14318), the third adds the 0.21.0 twin to the same receiver
  # so one notification reaches both binaries at the same millisecond.
  kubectl -n "${NS}" create secret generic perf-sentinel-incidents-key \
    --from-literal=api-key="${WRITE_KEY}" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null 2>&1
  python3 "${FIXTURES}/build_receiver.py" "${PROM_FILE}" "${TMP_DIR}/amc.yaml" \
    "http://perf-sentinel-daemon.${NS}.svc.cluster.local:14318/api/incidents" \
    "http://perf-sentinel-daemon-ab.${NS}.svc.cluster.local:14318/api/incidents" \
    || die "could not build the receiver"
  kubectl apply -f "${TMP_DIR}/amc.yaml" >/dev/null 2>&1 \
    || die "the API server refused the shipped AlertmanagerConfig"

  # Seed findings for the service the rules will derive, BEFORE any alert, so
  # the freeze window has something to freeze. An incident with an empty
  # findings array is recorded all the same and reports no error anywhere,
  # which is the quietest way this whole chain can look green and be useless.
  #
  # Since 0.24.0 the same seeding is also what lifts the untraced-services
  # record off the victim, so the alert fires at all. The Job's completion is
  # asserted rather than assumed: the record reads its counter over a whole
  # day and the daemon's ring outlives the run, so a Job that stopped running
  # would leave both of them answering from yesterday and this leg green on
  # evidence it did not produce.
  kubectl apply -f "${SCENARIO_DIR}/tracegen-job.yaml" >/dev/null 2>&1
  JOB_DONE=1
  kubectl -n "${NS}" wait --for=condition=complete job/tracegen-psbearer --timeout=240s >/dev/null 2>&1 \
    || JOB_DONE=0
  sleep 40
  SEEDED="$(curl -s "${DAEMON_URL}/api/findings?service=psbearer-probe-0000" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d if isinstance(d,list) else d.get("findings",[])))' 2>/dev/null)"

  # Wait for the rules to fire on real kube-state-metrics and cAdvisor series.
  FIRED=""
  for _ in $(seq 1 40); do
    FIRED="$(promq 'ALERTS{alertstate="firing",service="psbearer-probe-0000"}' \
      | python3 -c "
import json, sys
rows = json.load(sys.stdin)['data']['result']
print(' '.join(sorted({r['metric']['alertname'] for r in rows})))" 2>/dev/null)"
    [ -n "${FIRED}" ] && break
    sleep 10
  done

  if [ "${JOB_DONE}" = "1" ] && [ -n "${FIRED}" ] && [ "${SEEDED:-0}" -ge 1 ]; then
    ok "the seed Job completed on this run, so the ingest the record reads and"
    ok "the findings the window freezes both belong to it"
    ok "the shipped rules, applied unedited, fire on real series: ${FIRED}"
    ok "and derive service=psbearer-probe-0000 from the pod name, which is"
    ok "exactly the OTLP service.name the ${SEEDED} seeded findings carry"
    record "rules fire" PASS "${FIRED}, service derived, ${SEEDED} findings seeded"
  else
    fail "seed Job completed: ${JOB_DONE}, alerts fired: '${FIRED}', findings seeded: ${SEEDED:-0}"
    [ "${JOB_DONE}" = "1" ] || fail "(the Job runs lab-tracegen:1 with imagePullPolicy: Never, so \`make seed-tracegen\` first)"
    record "rules fire" FAIL "job_done=${JOB_DONE}, fired='${FIRED}', seeded=${SEEDED:-0}"
  fi

  # --- The namespace matcher, negative direction. The chart default appends a
  # matcher on the RESOURCE's namespace, while the alert carries the observed
  # workload's. Nothing matches, nothing is delivered, and no refusal is
  # counted either, because the delivery never leaves Alertmanager.
  ROUTE_DEFAULT="$(route_target)"
  ACTIVE_AT_AM="$(curl -s "${AM_URL}/api/v2/alerts" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(len([a for a in rows if a['labels'].get('alertname','').startswith('PerfSentinel')]))" 2>/dev/null)"
  N_TEST_0="$(incidents_count "${DAEMON_URL}")"
  U_TEST_0="$(unauth_count "${DAEMON_URL}")"
  sleep 90
  N_TEST_1="$(incidents_count "${DAEMON_URL}")"
  U_TEST_1="$(unauth_count "${DAEMON_URL}")"

  if [ "${ROUTE_DEFAULT}" = "null" ] && [ "${N_TEST_1}" = "${N_TEST_0}" ] && [ "${U_TEST_1}" = "${U_TEST_0}" ]; then
    ok "under the chart default the route resolves to null, and over 90 seconds"
    ok "no incident arrives AND no refusal is counted: the alert exists, it is"
    ok "live in Alertmanager, and the operator has nothing at all to read"
    record "namespace matcher" PASS "OnNamespace: route null, incidents and refusals both unchanged"
  else
    fail "route='${ROUTE_DEFAULT}', incidents ${N_TEST_0}->${N_TEST_1}, unauthorized ${U_TEST_0}->${U_TEST_1}"
    record "namespace matcher" FAIL "route='${ROUTE_DEFAULT}'"
  fi

  # --- Positive direction. One variable changes: the matcher strategy. Same
  # alert, same startsAt, same credential.
  U_TWIN_0="$(unauth_count "${TWIN_URL}")"
  kubectl -n "${NS}" patch alertmanager "${AM_CR}" --type=merge \
    -p '{"spec":{"alertmanagerConfigMatcherStrategy":{"type":"None"}}}' >/dev/null 2>&1
  ROUTE_NONE=""
  for _ in $(seq 1 40); do
    ROUTE_NONE="$(route_target)"
    [ -n "${ROUTE_NONE}" ] && [ "${ROUTE_NONE}" != "null" ] && break
    sleep 3
  done

  # A fresh ReplicaSet gives a new alert with a recent startsAt, so its freeze
  # window covers the findings seeded above rather than a window that closed
  # before they existed.
  kubectl -n "${VICTIM_NS}" rollout restart deploy/psbearer-probe-0000 >/dev/null 2>&1
  FROZEN=0
  for _ in $(seq 1 40); do
    FROZEN="$(curl -s -H "X-API-Key: ${WRITE_KEY}" "${DAEMON_URL}/api/incidents" 2>/dev/null \
      | python3 -c "
import json, sys
rows = json.load(sys.stdin)
print(max([len(i.get('findings', [])) for i in rows] + [0]))" 2>/dev/null)"
    [ "${FROZEN:-0}" -ge 1 ] && break
    sleep 10
  done
  INCIDENT="$(curl -s -H "X-API-Key: ${WRITE_KEY}" "${DAEMON_URL}/api/incidents" 2>/dev/null \
    | python3 "${FIXTURES}/describe_incident.py" 2>/dev/null)"
  N_TWIN="$(incidents_count "${TWIN_URL}")"
  U_TWIN_1="$(unauth_count "${TWIN_URL}")"

  if [ "${ROUTE_NONE}" != "null" ] && [ -n "${ROUTE_NONE}" ] && [ "${FROZEN:-0}" -ge 1 ] \
     && [ "${N_TWIN}" = "0" ] && [ "${U_TWIN_1}" -gt "${U_TWIN_0}" ]; then
    ok "with the matcher disabled the route resolves to ${ROUTE_NONE}"
    ok "a real Alertmanager posts the receiver's bearer credential and the"
    ok "daemon records: ${INCIDENT}"
    ok "the same delivery, same instant, against released 0.21.0: 0 incidents"
    ok "and unauthorized ${U_TWIN_0} -> ${U_TWIN_1}. Bearer is the mechanism."
    record "bearer delivers" PASS "${INCIDENT}; twin 0 incidents, unauthorized ${U_TWIN_0}->${U_TWIN_1}"
  else
    fail "route='${ROUTE_NONE}', frozen findings=${FROZEN}, twin incidents=${N_TWIN},"
    fail "twin unauthorized ${U_TWIN_0}->${U_TWIN_1}"
    record "bearer delivers" FAIL "route='${ROUTE_NONE}', frozen=${FROZEN}, twin=${N_TWIN}"
  fi
fi

# ---------------------------------------------------------------------------
step "J. The VictoriaMetrics twin against its own CRD"
# No VM operator runs here and installing one would mean a second complete
# monitoring stack, plus a converter that turns this lab's PrometheusRules and
# ServiceMonitors into VM resources by default. The CRDs alone are inert: no
# controller, no pod, nothing reconciles them. They are enough to put the twin
# file in front of the real OpenAPI schema, which is the part kubeconform could
# not do in leg F.
#
# This also settles a claim the example file and the CHANGELOG both make: that
# `http_headers` arrived late in this CRD and that an older API server "prunes
# the block in silence". Whether that mechanism is even possible depends on
# whether the schema is open or closed, and only the schema can say.
VM_OP_VERSION="${VM_OP_VERSION:-v0.74.1}"
VM_CRD_URL="https://raw.githubusercontent.com/VictoriaMetrics/operator/${VM_OP_VERSION}/config/crd/overlay/crd.yaml"
if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  skip "no cluster, the dry-run against a real API server needs one"
  record "VM CRD schema" SKIP "no cluster"
elif ! curl -sfL "${VM_CRD_URL}" -o "${TMP_DIR}/vm-crd.yaml" 2>/dev/null; then
  skip "could not fetch the VictoriaMetrics operator CRDs (offline?)"
  record "VM CRD schema" SKIP "CRD bundle unreachable"
else
  J_SCHEMA="$(python3 "${FIXTURES}/check_vm_crd.py" "${TMP_DIR}/vm-crd.yaml" 2>&1)"
  VM_CRDS_APPLIED=0
  if kubectl apply --server-side -f "${TMP_DIR}/vm-crd.yaml" >/dev/null 2>&1; then
    VM_CRDS_APPLIED=1
    # Wait for the API server to serve the new types before using them.
    for _ in $(seq 1 20); do
      kubectl get crd vmalertmanagerconfigs.operator.victoriametrics.com >/dev/null 2>&1 && break
      sleep 2
    done
    J_DRY="$(kubectl apply --dry-run=server -f "${VM_FILE}" 2>&1)"
    J_RC=$?
  else
    J_DRY="could not install the CRD bundle"
    J_RC=1
  fi

  # kubectl echoes the resource name lowercased (`vmrule.operator...`), so the
  # match has to be case-insensitive or this passes for the wrong reason.
  if [ "${J_RC}" = "0" ] && printf '%s' "${J_DRY}" | grep -qi 'vmrule' \
     && printf '%s' "${J_DRY}" | grep -qi 'vmalertmanagerconfig'; then
    ok "both VM resources accepted by a real API server carrying the ${VM_OP_VERSION} CRDs"
    ok "${J_SCHEMA}"
    record "VM CRD schema" PASS "VMRule and VMAlertmanagerConfig admitted, ${VM_OP_VERSION}"
  else
    fail "server-side dry run refused the twin file:"
    printf '%s\n' "${J_DRY}" | head -8
    record "VM CRD schema" FAIL "dry-run refused, see log"
  fi

  # Take the CRDs back out. They are inert, but leaving third-party types in a
  # shared lab is how the next scenario inherits a surprise.
  [ "${VM_CRDS_APPLIED}" = "1" ] && kubectl delete -f "${TMP_DIR}/vm-crd.yaml" \
    --ignore-not-found >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
step "Summary"
pass=0; failed=0; skipped=0
{
  echo "# ${SCENARIO}"
  echo
  echo "| Sub-test | Verdict | Note |"
  echo "|---|---|---|"
} > "${REPORT}"
for i in "${!NAMES[@]}"; do
  printf "  %-20s %-5s %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}"
  printf '| %s | %s | %s |\n' "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}" >> "${REPORT}"
  case "${VERDICTS[$i]}" in
    PASS) pass=$(( pass + 1 )) ;;
    FAIL) failed=$(( failed + 1 )) ;;
    SKIP) skipped=$(( skipped + 1 )) ;;
  esac
done
echo "  --- ${pass} PASS / ${failed} FAIL / ${skipped} SKIP ---"
{ echo; echo "${pass} PASS / ${failed} FAIL / ${skipped} SKIP"; } >> "${REPORT}"
step "Report written to ${REPORT}"
[ "${failed}" -eq 0 ] || { color_red "SCENARIO FAILED"; exit 1; }
color_green "SCENARIO PASSED"
