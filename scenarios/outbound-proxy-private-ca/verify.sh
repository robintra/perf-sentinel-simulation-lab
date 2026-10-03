#!/usr/bin/env bash
# outbound-proxy-private-ca: outbound HTTPS through a CONNECT proxy to an
# origin signed by a private CA, plus the daemon TLS listener (0.25.5).
#
# Setup, all throwaway: openssl mints a CA and a server certificate
# (SAN tls-origin, localhost, 127.0.0.1). One docker network holds
# `tls-origin` (nginx on :443 with that certificate) and a tinyproxy that
# logs every CONNECT and is published on 127.0.0.1. The host cannot resolve
# `tls-origin`, so a fetch that succeeds went through the tunnel.
#
# Assertions (verify-hash --url https://tls-origin/r/<path>, local binary):
#   V1 HTTPS_PROXY + SSL_CERT_FILE: exit 2, [OK] Content hash, CONNECT
#      tls-origin:443 in the proxy log.
#   V2 HTTPS_PROXY, no SSL_CERT_FILE: exit 4 on a certificate error, after
#      a CONNECT (the TLS failure is on the tunneled origin).
#   V3 no proxy variable: exit 4 on DNS, no CONNECT (V1 needed the tunnel).
#   V4 HTTPS_PROXY + NO_PROXY=tls-origin: exit 4, no CONNECT.
#   V5 only ALL_PROXY + SSL_CERT_FILE: exit 2, [OK] Content hash, CONNECT.
#   V6 HTTPS_PROXY=socks5://127.0.0.1:1: the "only http:// proxy URLs"
#      warning, direct connection failing on DNS, exit 4, no CONNECT.
#   V7 /r/redirect (302): exit 4 with "http status 302".
#   V8 /r/big (11 MiB): exit 4 on the 10 MiB body cap (10485760 bytes).
# Assertions (watch with [daemon] tls_cert_path/tls_key_path, query status):
#   T1 --daemon https://localhost:<port> with SSL_CERT_FILE: exit 0, and the
#      same call without it: non-zero, "HTTP transport error".
#   T2 HTTPS_PROXY set and NO_PROXY=localhost: exit 0, no CONNECT localhost.
#   T3 HTTPS_PROXY set, NO_PROXY unset: loopback is not exempt, the proxy
#      logs CONNECT localhost:<port>.
#
# 0.25.4 (ureq for verify-hash, no SSL_CERT_FILE anywhere, no proxy in the
# daemon client) fails V1, V5, V6, V7, V8, T1, T2 and T3.
set -euo pipefail

SCENARIO="outbound-proxy-private-ca"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
G2_FIXTURE="${LAB_ROOT}/scenarios/verify-hash-roundtrip/fixtures/example-official-public-G2.json"
rm -f "${REPORT}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
BIN="${PERF_SENTINEL_LOCAL_BIN}"

# Both images are small and pinned by digest: nginx 1.29 alpine-slim is about
# 22 MB, tinyproxy 1.11.3 about 24 MB.
ORIGIN_IMAGE="${ORIGIN_IMAGE:-nginx@sha256:c9366b8c560169b101ca0e5422ed063b20779e6454c2326b9c9704225c9b0c08}"
PROXY_IMAGE="${PROXY_IMAGE:-kalaksi/tinyproxy@sha256:fafafc7079ca29c6704564de1353f61d038f2166f09b01d4e460e8e499bf6b57}"

SUFFIX="opc-$$"
NET="ps-${SUFFIX}"
ORIGIN="tls-origin-${SUFFIX}"
PROXY="proxy-${SUFFIX}"
# AF_UNIX path must stay short (~104 chars), so /tmp and not mktemp's dir.
SOCK="/tmp/ps-${SUFFIX}.sock"
TMP_DIR=""
DAEMON_PID=""

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

cleanup() {
  [ -n "${DAEMON_PID}" ] && kill "${DAEMON_PID}" 2>/dev/null || true
  docker rm -f "${ORIGIN}" "${PROXY}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -f "${SOCK}" 2>/dev/null || true
  [ -n "${TMP_DIR}" ] && rm -rf "${TMP_DIR}" || true
}
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
# check <name> <note> <command...>: records PASS when the command succeeds.
check() {
  local name="$1" note="$2"; shift 2
  if "$@"; then
    ok "${name}: ${note}"; NAMES+=("${name}"); VERDICTS+=(PASS); NOTES+=("${note}")
  else
    fail "${name}: ${note}"; NAMES+=("${name}"); VERDICTS+=(FAIL); NOTES+=("${note}")
    printf '%s\n' "${OUT}" | tail -4 | sed 's/^/      | /'
  fi
}

# Every leg starts from an environment without proxy or trust variables.
CLEAN_ENV=(env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy
  -u HTTP_PROXY -u http_proxy -u NO_PROXY -u no_proxy -u SSL_CERT_FILE -u RUST_LOG)
OUT=""
RC=0
# run [VAR=value ...] -- <args>: runs the binary, sets OUT and RC.
run() {
  local -a vars=()
  while [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  set +e
  OUT="$("${CLEAN_ENV[@]}" ${vars[@]+"${vars[@]}"} "${BIN}" "$@" 2>&1)"
  RC=$?
  set -e
}
vh() { local path="$1"; shift; run "$@" -- verify-hash --url "https://tls-origin/r/${path}"; }

# A docker failure must stop the run, never read as "0 CONNECT".
connects() {
  local log
  # stderr, since stdout is captured. The failed $(...) then stops set -e.
  log="$(docker logs "${PROXY}" 2>&1)" || die "docker logs ${PROXY} failed: ${log}" >&2
  printf '%s\n' "${log}" | grep -c "CONNECT $1" || true
}
has()  { printf '%s\n' "${OUT}" | grep -qiE "$1"; }
DNS_RE='dns error|failed to lookup|nodename nor servname|name or service not known'
CERT_RE='certificate|UnknownIssuer|unknown issuer'

step "0. Pre-flight"
[ -x "${BIN}" ] || die "no local binary at ${BIN} (cargo build --release -p perf-sentinel first)"
for c in docker openssl curl python3; do command -v "${c}" >/dev/null || die "${c} not on PATH"; done
# V3, V4 and V6 need the host to fail on tls-origin, so a resolving search
# domain or /etc/hosts entry is a setup fault, not a product one.
python3 -c 'import socket; socket.gethostbyname("tls-origin")' 2>/dev/null \
  && die "the host resolves tls-origin, V3, V4 and V6 cannot prove a direct connection"
[ -f "${G2_FIXTURE}" ] || die "fixture missing: ${G2_FIXTURE}"
for img in "${ORIGIN_IMAGE}" "${PROXY_IMAGE}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || docker pull "${img}" >/dev/null || die "cannot pull ${img}"
done
ok "binary perf-sentinel $("${BIN}" --version | awk '{print $2}')"

step "1. Throwaway CA, server certificate, served files"
TMP_DIR="$(mktemp -d "/tmp/${SCENARIO}.XXXXXX")"
mkdir -p "${TMP_DIR}/tls" "${TMP_DIR}/www/r"
(
  cd "${TMP_DIR}/tls"
  openssl req -x509 -new -nodes -newkey rsa:2048 -days 1 -keyout ca.key -out ca.pem \
    -config "${FIX}/openssl.cnf" -extensions ca_ext 2>/dev/null
  openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr \
    -config "${FIX}/openssl.cnf" 2>/dev/null
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 \
    -extfile "${FIX}/openssl.cnf" -extensions srv_ext -out server.pem 2>/dev/null
) || die "openssl failed"
CA="${TMP_DIR}/tls/ca.pem"
run -- hash-bake --report "${G2_FIXTURE}" --output "${TMP_DIR}/www/r/report.json"
[ "${RC}" -eq 0 ] || die "hash-bake failed: ${OUT}"
head -c $((11 * 1024 * 1024)) /dev/zero > "${TMP_DIR}/www/r/big"
chmod -R a+rX "${TMP_DIR}/www"
ok "CA + server cert (SAN tls-origin, localhost, 127.0.0.1), baked report, 11 MiB body"

step "2. Origin and proxy on network ${NET}"
docker network create "${NET}" >/dev/null
docker run -d --name "${ORIGIN}" --network "${NET}" --network-alias tls-origin \
  --entrypoint nginx \
  -v "${FIX}/nginx.conf:/srv/nginx.conf:ro" -v "${TMP_DIR}/tls:/srv/tls:ro" -v "${TMP_DIR}/www:/srv/www:ro" \
  "${ORIGIN_IMAGE}" -c /srv/nginx.conf -g 'daemon off;' >/dev/null
docker run -d --name "${PROXY}" --network "${NET}" -p 127.0.0.1::8888 "${PROXY_IMAGE}" >/dev/null
PROXY_PORT="$(docker port "${PROXY}" 8888/tcp | head -1 | awk -F: '{print $NF}')"
PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
# Independent readiness probe, so a setup fault never reads as a product fault.
for _ in $(seq 1 30); do
  "${CLEAN_ENV[@]}" curl -sf --proxy "${PROXY_URL}" --cacert "${CA}" -o /dev/null https://tls-origin/r/report.json && break
  sleep 1
done
"${CLEAN_ENV[@]}" curl -sf --proxy "${PROXY_URL}" --cacert "${CA}" -o /dev/null https://tls-origin/r/report.json \
  || die "curl cannot reach the origin through the proxy: $(docker logs "${ORIGIN}" 2>&1 | tail -3)"
ok "proxy on ${PROXY_URL}, origin answers through it"

step "3. verify-hash --url through the proxy"
before=$(connects tls-origin:443)
vh report.json HTTPS_PROXY="${PROXY_URL}" SSL_CERT_FILE="${CA}"
after=$(connects tls-origin:443)
v1() { [ "${RC}" -eq 2 ] && has '\[OK\] Content hash' && [ "${after}" -gt "${before}" ]; }
check V1 "HTTPS_PROXY + SSL_CERT_FILE: exit=${RC}, CONNECT +$((after - before))" v1

before=${after}
vh report.json HTTPS_PROXY="${PROXY_URL}"
after=$(connects tls-origin:443)
v2() { [ "${RC}" -eq 4 ] && has "${CERT_RE}" && [ "${after}" -gt "${before}" ]; }
check V2 "no SSL_CERT_FILE: exit=${RC}, certificate error, CONNECT +$((after - before))" v2

before=${after}
vh report.json
after=$(connects tls-origin:443)
v3() { [ "${RC}" -eq 4 ] && has "${DNS_RE}" && [ "${after}" -eq "${before}" ]; }
check V3 "no proxy: exit=${RC}, DNS failure, CONNECT +$((after - before))" v3

before=${after}
vh report.json HTTPS_PROXY="${PROXY_URL}" NO_PROXY=tls-origin SSL_CERT_FILE="${CA}"
after=$(connects tls-origin:443)
v4() { [ "${RC}" -eq 4 ] && has "${DNS_RE}" && [ "${after}" -eq "${before}" ]; }
check V4 "NO_PROXY=tls-origin: exit=${RC}, DNS failure, CONNECT +$((after - before))" v4

before=${after}
vh report.json ALL_PROXY="${PROXY_URL}" SSL_CERT_FILE="${CA}"
after=$(connects tls-origin:443)
v5() { [ "${RC}" -eq 2 ] && has '\[OK\] Content hash' && [ "${after}" -gt "${before}" ]; }
check V5 "ALL_PROXY only: exit=${RC}, CONNECT +$((after - before))" v5

before=${after}
vh report.json HTTPS_PROXY=socks5://127.0.0.1:1 SSL_CERT_FILE="${CA}"
after=$(connects tls-origin:443)
v6() { [ "${RC}" -eq 4 ] && has 'only http:// proxy URLs are supported' && has "${DNS_RE}" && [ "${after}" -eq "${before}" ]; }
check V6 "socks5 HTTPS_PROXY: exit=${RC}, warning + direct DNS failure" v6

vh redirect HTTPS_PROXY="${PROXY_URL}" SSL_CERT_FILE="${CA}"
v7() { [ "${RC}" -eq 4 ] && has 'http status 302'; }
check V7 "/r/redirect: exit=${RC}, redirect refused" v7

vh big HTTPS_PROXY="${PROXY_URL}" SSL_CERT_FILE="${CA}"
v8() { [ "${RC}" -eq 4 ] && has 'exceeds 10485760 byte cap'; }
check V8 "/r/big: exit=${RC}, 10485760 byte cap" v8

step "4. Daemon TLS listener queried over https://localhost"
read -r HTTP_PORT GRPC_PORT < <(python3 -c '
import socket
s = [socket.socket() for _ in range(2)]
for x in s: x.bind(("127.0.0.1", 0))
print(*[x.getsockname()[1] for x in s])')
cat > "${TMP_DIR}/daemon.toml" <<EOF
[daemon]
listen_address = "127.0.0.1"
listen_port_http = ${HTTP_PORT}
listen_port_grpc = ${GRPC_PORT}
json_socket = "${SOCK}"
api_enabled = true
tls_cert_path = "${TMP_DIR}/tls/server.pem"
tls_key_path = "${TMP_DIR}/tls/server.key"

[daemon.ack]
enabled = false
EOF
"${CLEAN_ENV[@]}" "${BIN}" watch --config "${TMP_DIR}/daemon.toml" > "${TMP_DIR}/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 30); do
  curl -sk --noproxy '*' -o /dev/null "https://127.0.0.1:${HTTP_PORT}/api/status" && break
  kill -0 "${DAEMON_PID}" 2>/dev/null || die "daemon died: $(tail -3 "${TMP_DIR}/daemon.log")"
  sleep 0.5
done
curl -sk --noproxy '*' -o /dev/null "https://127.0.0.1:${HTTP_PORT}/api/status" || die "daemon TLS listener not up"
ok "daemon serving TLS on 127.0.0.1:${HTTP_PORT}"
DAEMON_URL="https://localhost:${HTTP_PORT}"

run SSL_CERT_FILE="${CA}" -- query --daemon "${DAEMON_URL}" status
t1_ca=${RC}
run -- query --daemon "${DAEMON_URL}" status
t1_noca=${RC}
# `query` prints "HTTP transport error" without the TLS cause, so the proof
# that trust is what fails is the pair: same call, only SSL_CERT_FILE differs.
t1() { [ "${t1_ca}" -eq 0 ] && [ "${t1_noca}" -ne 0 ] && has 'transport error'; }
check T1 "with SSL_CERT_FILE exit=${t1_ca}, without exit=${t1_noca} (transport error)" t1

before=$(connects "localhost:${HTTP_PORT}")
run HTTPS_PROXY="${PROXY_URL}" NO_PROXY=localhost SSL_CERT_FILE="${CA}" -- query --daemon "${DAEMON_URL}" status
after=$(connects "localhost:${HTTP_PORT}")
t2() { [ "${RC}" -eq 0 ] && [ "${after}" -eq "${before}" ]; }
check T2 "HTTPS_PROXY + NO_PROXY=localhost: exit=${RC}, CONNECT +$((after - before))" t2

run HTTPS_PROXY="${PROXY_URL}" SSL_CERT_FILE="${CA}" -- query --daemon "${DAEMON_URL}" status
after=$(connects "localhost:${HTTP_PORT}")
t3() { [ "${RC}" -ne 0 ] && [ "${after}" -gt "${before}" ]; }
check T3 "HTTPS_PROXY without NO_PROXY: exit=${RC}, loopback tunneled, CONNECT +$((after - before))" t3

overall=PASS
for v in "${VERDICTS[@]}"; do [ "${v}" = FAIL ] && overall=FAIL; done
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Binary: ${BIN} ($("${BIN}" --version))"
  echo
  echo "| Leg | Verdict | Note |"
  echo "| --- | --- | --- |"
  for i in "${!NAMES[@]}"; do echo "| ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"; done
  echo
  echo "## Verdict: ${overall}"
} > "${REPORT}"

if [ "${overall}" = PASS ]; then
  ok "PASS ${#NAMES[@]}/${#NAMES[@]} in ${SECONDS}s, see ${REPORT}"
else
  fail "see ${REPORT}"
  exit 1
fi
