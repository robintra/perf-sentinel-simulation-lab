#!/usr/bin/env bash
# daemon-sigterm-drain: prove the v0.8.5 graceful-drain-on-SIGTERM contract.
#
# v0.8.5 routes the daemon event loop through crate::shutdown::shutdown_signal(),
# which resolves on SIGINT AND (on Unix) SIGTERM, so a normal Kubernetes pod
# termination (rolling update, scale-down, node drain -- all SIGTERM) now flushes
# the in-flight streaming window through detection instead of dropping it. Only an
# ungraceful kill (SIGKILL after the grace period, OOM) still loses the window.
# Before 0.8.5 only SIGINT drained, so a SIGTERM lost the current window.
#
# This scenario closes the coverage gap left by failure-mode-daemon-restart, whose
# "may be lost (graceful drop)" wording encodes the OLD contract. We use a genuine
# before/after test with a positive and a negative control so a PASS means "the
# drain saved the window", not "a finding happened to appear":
#
#   Positive control  -- 0.8.5, graceful SIGTERM (scale-to-0): the in-flight N+1
#                        is flushed to the per-window NDJSON archive.
#   Negative control  -- 0.8.5, ungraceful SIGKILL (kill -9 the daemon PID on its
#                        k3d node): the in-flight N+1 is lost, never archived.
#   Regression sanity -- daemon comes back, /api/status answers, no panic/FATAL,
#                        ingestion resumes.
#
# Counter-check (run separately, see README): with SIGTERM_DRAIN_IMAGE pointed at a
# 0.8.4 image the positive control FAILS, proving the test measures the new behavior.
#
# Capture surface: the opt-in per-window NDJSON archive ([daemon.archive]) on the
# writable acks PVC. Upstream LIMITATIONS.md calls it "the one place a gap is
# visible" on an ungraceful kill, so it is the natural before/after surface. Both
# controls read the same archive via a reader pod, so the contrast is apples-to-
# apples. Assertions are keyed on a per-control marker (probe_positive /
# probe_negative) so background lab traffic in the shared daemon cannot alias them.
#
# Timing subtlety: the scenario raises trace_ttl_ms to 30000 in a scoped ConfigMap
# so the injected trace stays genuinely in-flight (no TTL finalization) when the
# signal lands. The kill happens seconds after injection, far inside the 30s TTL,
# so a positive result is attributable to the drain, never to TTL eviction.

set -euo pipefail

SCENARIO="daemon-sigterm-drain"
NS="daemon-sigterm-drain"          # dedicated namespace for the injector Job
OBS_NS="observability"
DEPLOY="perf-sentinel-daemon"
DAEMON_SELECTOR="app.kubernetes.io/name=perf-sentinel-daemon"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX_DIR="$(cd "$(dirname "$0")" && pwd)/fixtures"
mkdir -p "${TMP_DIR}"

DAEMON_LOCAL_PORT="${DAEMON_LOCAL_PORT:-14318}"
# Image under test. Default: the published 0.8.5 image. Override with a 0.8.4
# image for the counter-check, or a local build (perf-sentinel:0.8.5-lab) before
# the official digest is published.
SIGTERM_DRAIN_IMAGE="${SIGTERM_DRAIN_IMAGE:-ghcr.io/robintra/perf-sentinel:0.8.5}"
ARCHIVE_PATH="/var/lib/perf-sentinel/${SCENARIO}-archive.ndjson"
INJECT_IMAGE="${INJECT_IMAGE:-curlimages/curl:8.11.1}"
PVC_UTIL_IMAGE="${PVC_UTIL_IMAGE:-busybox:1.37}"
SCALEDOWN_TIMEOUT="${SCALEDOWN_TIMEOUT:-90}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }  # cleanup runs via the EXIT trap

cleanup() {
  if [ "${KEEP_NAMESPACE:-no}" = "yes" ]; then
    return
  fi
  # Free the ReadWriteOnce PVC (scale to 0) so the scenario archive can be
  # removed, then restore the committed daemon (image, ConfigMap, grace, and
  # replicas=1 via the manifest), the injector namespace, and the daemon ingress
  # allow. Everything is best-effort so a mid-phase failure still tears down.
  scale_daemon 0 >/dev/null 2>&1 || true
  wait_daemon_gone || true
  rm_archive_file >/dev/null 2>&1 || true
  delete_pvc_helpers
  kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null 2>&1 || true
  kubectl delete networkpolicy "perf-sentinel-allow-${NS}" -n "${OBS_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  pf_restart >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------

pf_restart() {
  # Re-establish the daemon port-forward after a rollout/scale; the previous one
  # is a zombie pointing at an endpoint that no longer exists (same handling as
  # failure-mode-daemon-restart).
  pkill -f "kubectl.*port-forward.*${DEPLOY}" 2>/dev/null || true
  rm -f "${REPO_ROOT}/tmp/pf-daemon.pid" 2>/dev/null || true
  sleep 2
  "${REPO_ROOT}/scripts/port-forward.sh" start >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

daemon_replicas() {
  kubectl -n "${OBS_NS}" get pod -l "${DAEMON_SELECTOR}" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

wait_daemon_gone() {
  for _ in $(seq 1 "${SCALEDOWN_TIMEOUT}"); do
    [ "$(daemon_replicas)" = "0" ] && return 0
    sleep 1
  done
  return 1
}

scale_daemon() {
  kubectl -n "${OBS_NS}" scale deploy/"${DEPLOY}" --replicas="$1" >/dev/null
}

daemon_up() {
  scale_daemon 1
  kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=120s >/dev/null
  pf_restart || die "daemon did not answer /api/status after scale-up"
}

# Run a one-shot busybox pod mounting the acks PVC read-write and exec a command.
# Used to reset the archive between controls (the PVC is ReadWriteOnce, so this is
# only safe while the daemon is scaled to 0).
pvc_exec_rw() {
  delete_pvc_helpers
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${SCENARIO}-util, namespace: ${OBS_NS}, labels: { app.kubernetes.io/part-of: perf-sentinel-lab } }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: util
      image: ${PVC_UTIL_IMAGE}
      command: ["sh","-c","sleep 120"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [ { name: data, mountPath: /data } ]
  volumes: [ { name: data, persistentVolumeClaim: { claimName: perf-sentinel-acks } } ]
EOF
  kubectl -n "${OBS_NS}" wait --for=condition=Ready pod/"${SCENARIO}-util" --timeout=90s >/dev/null
  kubectl -n "${OBS_NS}" exec "${SCENARIO}-util" -- sh -c "$1"
  kubectl -n "${OBS_NS}" delete pod "${SCENARIO}-util" --grace-period=1 --wait=true >/dev/null 2>&1 || true
}

delete_pvc_helpers() {
  kubectl -n "${OBS_NS}" delete pod "${SCENARIO}-util" "${SCENARIO}-reader" --grace-period=1 --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

rm_archive_file() {
  # Must run with the daemon scaled to 0 (RWO PVC).
  pvc_exec_rw "rm -f /data/$(basename "${ARCHIVE_PATH}")"
}

# Count archive lines carrying MARKER. Reads through a read-only reader pod, so it
# requires the daemon scaled to 0 (RWO PVC). Prints a single integer.
archive_marker_count() {
  local marker="$1" base; base="$(basename "${ARCHIVE_PATH}")"
  delete_pvc_helpers
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${SCENARIO}-reader, namespace: ${OBS_NS}, labels: { app.kubernetes.io/part-of: perf-sentinel-lab } }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: reader
      image: ${PVC_UTIL_IMAGE}
      command: ["sh","-c","sleep 120"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [ { name: data, mountPath: /data, readOnly: true } ]
  volumes: [ { name: data, persistentVolumeClaim: { claimName: perf-sentinel-acks, readOnly: true } } ]
EOF
  if ! kubectl -n "${OBS_NS}" wait --for=condition=Ready pod/"${SCENARIO}-reader" --timeout=90s >/dev/null 2>&1; then
    kubectl -n "${OBS_NS}" delete pod "${SCENARIO}-reader" --grace-period=1 --wait=false >/dev/null 2>&1 || true
    echo "READFAIL"; return 0
  fi
  # Append an __OK__ sentinel: a swallowed exec/transport failure would otherwise
  # print nothing and look identical to a legitimate zero-match, which on the
  # negative control is a false PASS. The caller dies on READFAIL.
  local out rc
  out="$(kubectl -n "${OBS_NS}" exec "${SCENARIO}-reader" -- sh -c "if [ -f /data/${base} ]; then grep -c '${marker}' /data/${base} || true; else echo 0; fi; echo __OK__" 2>/dev/null)"; rc=$?
  kubectl -n "${OBS_NS}" delete pod "${SCENARIO}-reader" --grace-period=1 --wait=true >/dev/null 2>&1 || true
  if [ "${rc}" -ne 0 ] || ! printf '%s' "${out}" | grep -q __OK__; then
    echo "READFAIL"; return 0
  fi
  printf '%s\n' "${out}" | grep -v __OK__ | tail -1
}

# Inject one fixture through an in-cluster Job that POSTs OTLP/protobuf to the
# daemon Service on 14318, traversing the NetworkPolicy pair. The retry loop
# absorbs Cilium policy-propagation lag on the first pod of a fresh namespace.
inject_fixture() {
  local fixture="$1" job="inject-$2"
  kubectl -n "${NS}" delete job "${job}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: ${job}, namespace: ${NS} }
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 65534, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: inject
          image: ${INJECT_IMAGE}
          command: ["sh","-c","for i in \$(seq 1 30); do code=\$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://${DEPLOY}.${OBS_NS}.svc.cluster.local:14318/v1/traces -H 'Content-Type: application/x-protobuf' --data-binary @/fixtures/${fixture} 2>/dev/null); echo \"attempt \$i -> HTTP \$code\"; [ \"\$code\" = \"200\" ] && exit 0; sleep 2; done; echo 'injection failed after retries'; exit 1"]
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          volumeMounts: [ { name: fixtures, mountPath: /fixtures, readOnly: true } ]
      volumes: [ { name: fixtures, configMap: { name: ${SCENARIO}-fixtures } } ]
EOF
  if ! kubectl -n "${NS}" wait --for=condition=complete job/"${job}" --timeout=120s >/dev/null 2>&1; then
    kubectl -n "${NS}" logs job/"${job}" > "${TMP_DIR}/${job}.log" 2>&1 || true
    return 1
  fi
}

# True SIGKILL of the daemon process via its k3d node's containerd. A K8s-level
# delete (even --grace-period=0 --force) still routes through the kubelet's SIGTERM,
# which the fast drain completes before SIGKILL lands; killing the PID directly is
# the only signal that bypasses the drain, modelling an OOM / over-grace kill.
sigkill_daemon_pid() {
  local pod node cid pid
  pod="$(kubectl -n "${OBS_NS}" get pod -l "${DAEMON_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')"
  node="$(kubectl -n "${OBS_NS}" get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
  cid="$(docker exec "${node}" crictl ps --name perf-sentinel -q 2>/dev/null | head -1)"
  [ -n "${cid}" ] || return 1
  pid="$(docker exec "${node}" crictl inspect "${cid}" 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['info']['pid'])")"
  [ -n "${pid}" ] || return 1
  echo "SIGKILL daemon pid ${pid} on ${node} (container ${cid:0:12})"
  docker exec "${node}" kill -9 "${pid}"
}

# --- preflight ----------------------------------------------------------------

verdict="UNKNOWN"
POS_COUNT=0; NEG_COUNT=0; PANICS=0; SANITY_INGEST="no"; DAEMON_ALIVE="no"
DAEMON_VERSION="unknown"

step "Preflight: cluster, daemon, image, fixtures"
kubectl get ns "${OBS_NS}" >/dev/null 2>&1 || die "namespace ${OBS_NS} missing; run make up-cni"
[ -f "${FIX_DIR}/n-plus-one-positive.pb" ] && [ -f "${FIX_DIR}/n-plus-one-negative.pb" ] \
  || die "OTLP fixtures missing under ${FIX_DIR} (regenerate with fixtures/generate.py)"
command -v docker >/dev/null 2>&1 || die "docker CLI required for the node-level SIGKILL negative control"
# Confirm the image under test is loadable on the k3d nodes (digests are pulled,
# the local 0.8.5 tag must be imported first).
if ! docker exec "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" crictl images 2>/dev/null \
      | grep -qF "$(echo "${SIGTERM_DRAIN_IMAGE}" | sed 's/@sha256:.*//; s/:.*$//')"; then
  color_red "    warning: ${SIGTERM_DRAIN_IMAGE} not found on a node; relying on imagePullPolicy/import"
fi
ok "preflight checks passed (image under test: ${SIGTERM_DRAIN_IMAGE})"

# --- setup: scoped config + image under test ---------------------------------

step "Apply scenario namespace, NetworkPolicy pair and fixture ConfigMap"
# If a prior run's namespace is still terminating, wait it out before recreating.
if kubectl get namespace "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
  kubectl wait --for=delete namespace/"${NS}" --timeout=90s >/dev/null 2>&1 || true
fi
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label ns "${NS}" app.kubernetes.io/part-of=perf-sentinel-lab \
  pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
kubectl -n "${NS}" create configmap "${SCENARIO}-fixtures" \
  --from-file=n-plus-one-positive.pb="${FIX_DIR}/n-plus-one-positive.pb" \
  --from-file=n-plus-one-negative.pb="${FIX_DIR}/n-plus-one-negative.pb" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >"${TMP_DIR}/netpol.log" 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: ${NS}-egress, namespace: ${NS} }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }, podSelector: { matchLabels: { k8s-app: kube-dns } } } ]
      ports: [ { protocol: UDP, port: 53 }, { protocol: TCP, port: 53 } ]
    - to: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ${OBS_NS} } }, podSelector: { matchLabels: { app.kubernetes.io/name: perf-sentinel-daemon } } } ]
      ports: [ { protocol: TCP, port: 14318 } ]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: perf-sentinel-allow-${NS}, namespace: ${OBS_NS} }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: perf-sentinel-daemon } }
  policyTypes: [Ingress]
  ingress:
    - from: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ${NS} } } } ]
      ports: [ { protocol: TCP, port: 14318 } ]
EOF
ok "namespace, NetworkPolicies and fixtures applied"

step "Reconfigure daemon: scoped config (trace_ttl_ms=30000 + archive) + image under test"
# Start from the committed baseline so the scoped config derives from the real
# ConfigMap regardless of any prior partial run.
kubectl apply -f "${REPO_ROOT}/manifests/perf-sentinel-daemon.yaml" >/dev/null
kubectl -n "${OBS_NS}" get cm perf-sentinel-daemon-config -o jsonpath='{.data.config\.toml}' > "${TMP_DIR}/base-config.toml"
sed 's/trace_ttl_ms = 5000/trace_ttl_ms = 30000/' "${TMP_DIR}/base-config.toml" > "${TMP_DIR}/scoped-config.toml"
cat >> "${TMP_DIR}/scoped-config.toml" <<EOF

    [daemon.archive]
    # Scenario-scoped per-window NDJSON archive on the writable acks PVC mount
    # (the rootfs is read-only). The SIGTERM drain flushes the in-flight window
    # here; an ungraceful SIGKILL does not. Removed at scenario cleanup.
    path = "${ARCHIVE_PATH}"
EOF
# Fail loud if the TTL override silently no-op'd (committed value/spacing drift):
# a short TTL would finalize the trace by eviction and defeat the in-flight premise.
grep -q 'trace_ttl_ms = 30000' "${TMP_DIR}/scoped-config.toml" \
  || die "scoped config missing 'trace_ttl_ms = 30000' (committed value changed? the sed matched nothing)"
kubectl -n "${OBS_NS}" create configmap perf-sentinel-daemon-config \
  --from-file=config.toml="${TMP_DIR}/scoped-config.toml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${OBS_NS}" set image deploy/"${DEPLOY}" perf-sentinel="${SIGTERM_DRAIN_IMAGE}" >/dev/null
scale_daemon 1
kubectl -n "${OBS_NS}" rollout status deploy/"${DEPLOY}" --timeout=180s >/dev/null || die "daemon rollout failed on ${SIGTERM_DRAIN_IMAGE}"
pf_restart || die "daemon unreachable after reconfigure"
DAEMON_VERSION="$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))')"
ok "daemon ready, version=${DAEMON_VERSION}, trace_ttl_ms=30000, archive=${ARCHIVE_PATH}"

# --- positive control: graceful SIGTERM drains the in-flight window -----------

step "POSITIVE control: inject N+1, graceful SIGTERM (scale-to-0), expect drain"
scale_daemon 0; wait_daemon_gone || die "daemon did not scale to 0 before positive reset"
rm_archive_file
daemon_up
inject_fixture "n-plus-one-positive.pb" "positive" || die "positive injection Job failed (see ${TMP_DIR})"
ok "injected probe_positive (in-flight; trace_ttl_ms=30000 >> kill delay)"
step "graceful SIGTERM via scale-to-0"
scale_daemon 0
wait_daemon_gone || die "daemon pod did not terminate within ${SCALEDOWN_TIMEOUT}s"
POS_COUNT="$(archive_marker_count probe_positive)"
[ "${POS_COUNT}" = "READFAIL" ] && die "positive control: could not read the archive (reader pod exec failed)"
if [ "${POS_COUNT}" -ge 1 ]; then
  ok "probe_positive archived (${POS_COUNT} window) -- drain saved the in-flight window"
else
  color_red "    probe_positive NOT archived -- graceful SIGTERM did not drain (expected on 0.8.4)"
fi

# --- negative control: ungraceful SIGKILL loses the window --------------------

step "NEGATIVE control: inject N+1, ungraceful SIGKILL, expect loss"
rm_archive_file
daemon_up
inject_fixture "n-plus-one-negative.pb" "negative" || die "negative injection Job failed (see ${TMP_DIR})"
ok "injected probe_negative (in-flight)"
sigkill_daemon_pid > "${TMP_DIR}/sigkill.log" 2>&1 || die "could not SIGKILL the daemon process on its node"
cat "${TMP_DIR}/sigkill.log" | sed 's/^/    /'
# The kubelet restarts the container in place; scale to 0 so the PVC frees for the
# reader. The restarted container's window never held probe_negative.
sleep 2
scale_daemon 0
wait_daemon_gone || die "daemon pod did not terminate after SIGKILL within ${SCALEDOWN_TIMEOUT}s"
NEG_COUNT="$(archive_marker_count probe_negative)"
[ "${NEG_COUNT}" = "READFAIL" ] && die "negative control: could not read the archive (reader pod exec failed) -- cannot certify the window was lost"
if [ "${NEG_COUNT}" -eq 0 ]; then
  ok "probe_negative absent (${NEG_COUNT}) -- ungraceful kill lost the in-flight window"
else
  color_red "    probe_negative present (${NEG_COUNT}) -- SIGKILL unexpectedly drained"
fi

# --- regression sanity --------------------------------------------------------

step "REGRESSION sanity: daemon recovers, no panic, ingestion resumes"
daemon_up
DAEMON_ALIVE="$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" >/dev/null 2>&1 && echo yes || echo no)"
PANICS="$(kubectl -n "${OBS_NS}" logs deploy/"${DEPLOY}" --since=5m 2>/dev/null | grep -ic -E "panic|FATAL" || true)"
PANICS="${PANICS:-0}"
inject_fixture "n-plus-one-positive.pb" "sanity" || true
sleep 2
ACTIVE="$(curl -fsS "http://localhost:${DAEMON_LOCAL_PORT}/api/status" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("active_traces",0))' 2>/dev/null || echo 0)"
SANITY_INGEST="$([ "${ACTIVE}" -gt 0 ] && echo yes || echo no)"
ok "daemon /api/status answers: ${DAEMON_ALIVE}; panic/FATAL hits: ${PANICS}; ingestion resumed: ${SANITY_INGEST} (active_traces=${ACTIVE})"

# --- verdict ------------------------------------------------------------------

PASS_POSITIVE=$([ "${POS_COUNT}" -ge 1 ] && echo yes || echo no)
PASS_NEGATIVE=$([ "${NEG_COUNT}" -eq 0 ] && echo yes || echo no)
PASS_SANITY=$([ "${DAEMON_ALIVE}" = "yes" ] && [ "${PANICS}" -eq 0 ] && [ "${SANITY_INGEST}" = "yes" ] && echo yes || echo no)
if [ "${PASS_POSITIVE}" = "yes" ] && [ "${PASS_NEGATIVE}" = "yes" ] && [ "${PASS_SANITY}" = "yes" ]; then
  verdict="PASS"
else
  verdict="FAIL"
fi

step "Write report"
{
  echo "# ${SCENARIO}"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Image under test: ${SIGTERM_DRAIN_IMAGE} (daemon reported version: ${DAEMON_VERSION})"
  echo "Namespace: ${NS} (+ reader/util pods in ${OBS_NS}); cleaned up unless KEEP_NAMESPACE=yes"
  echo
  echo "## What this proves"
  echo
  echo "v0.8.5 drains the in-flight streaming window on SIGTERM (Unix), not only SIGINT,"
  echo "so a graceful Kubernetes pod termination flushes the window through detection."
  echo "Capture surface: per-window NDJSON archive at ${ARCHIVE_PATH}."
  echo
  echo "## Controls"
  echo
  echo "- POSITIVE  (graceful SIGTERM / scale-to-0): probe_positive archived windows = ${POS_COUNT} (expect >= 1)"
  echo "- NEGATIVE  (ungraceful SIGKILL of daemon PID): probe_negative archived windows = ${NEG_COUNT} (expect 0)"
  echo "- timing: trace_ttl_ms=30000, kill within seconds of injection -> TTL eviction ruled out"
  echo
  echo "## Verdicts"
  echo
  echo "- positive control (drain saved the window): ${PASS_POSITIVE}"
  echo "- negative control (SIGKILL lost the window): ${PASS_NEGATIVE}"
  echo "- regression sanity (alive=${DAEMON_ALIVE}, panics=${PANICS}, ingest=${SANITY_INGEST}): ${PASS_SANITY}"
  echo
  echo "**Verdict: ${verdict}**"
} > "${REPORT}"

if [ "${verdict}" = "PASS" ]; then
  ok "PASS, see ${REPORT}"
  exit 0
else
  die "${verdict}, see ${REPORT}"
fi
