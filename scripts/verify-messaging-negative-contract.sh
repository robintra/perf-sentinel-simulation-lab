#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ "$1" != quarkus ]; then
    echo "usage: $(basename "$0") quarkus" >&2
    exit 2
fi

NAMESPACE="${NAMESPACE:-shop}"
SERVICE_URL="http://quarkus-svc.${NAMESPACE}.svc.cluster.local:8083"
JOB="messaging-negative-contract-quarkus"
CM="${JOB}-script"
broker_before="$(kubectl -n messaging exec deploy/rabbitmq -- rabbitmqctl list_connections -q | wc -l)"
trap 'kubectl -n "${NAMESPACE}" delete job "${JOB}" --ignore-not-found >/dev/null; kubectl -n "${NAMESPACE}" delete configmap "${CM}" --ignore-not-found >/dev/null' EXIT

kubectl -n "${NAMESPACE}" delete job "${JOB}" --ignore-not-found >/dev/null
kubectl -n "${NAMESPACE}" create configmap "${CM}" --from-literal=script.js='import http from "k6/http";
import { check } from "k6";
export const options = { vus: 1, iterations: 1, thresholds: { checks: ["rate==1"] } };
const paths = ["/api/fault/n-plus-one-messaging?messages=4", "/api/fault/n-plus-one-messaging?messages=101", "/api/fault/slow-messaging?delayMs=500&repeats=3", "/api/fault/slow-messaging?delayMs=5001&repeats=3", "/api/fault/slow-messaging?delayMs=600&repeats=2", "/api/fault/slow-messaging?delayMs=600&repeats=21", "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported"];
export default function () { for (const path of paths) check(http.post(`${__ENV.SERVICE_URL}${path}`), { "HTTP 400": r => r.status === 400 }); }' --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:1.7.1
          env:
            - name: SERVICE_URL
              value: ${SERVICE_URL}
          args: ["run", "--quiet", "/scripts/script.js"]
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: ${CM}
EOF
if ! kubectl -n "${NAMESPACE}" wait "job/${JOB}" --for=condition=Complete --timeout=120s >/dev/null; then
    kubectl -n "${NAMESPACE}" logs "job/${JOB}" --tail=100 >&2 || true
    exit 1
fi
broker_after="$(kubectl -n messaging exec deploy/rabbitmq -- rabbitmqctl list_connections -q | wc -l)"
[ "${broker_before}" = "${broker_after}" ] || { echo "broker connection count changed" >&2; exit 1; }
echo "PASS: 7/7 HTTP 400, broker calls 0, toxic calls 0"
