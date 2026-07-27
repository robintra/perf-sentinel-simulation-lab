#!/usr/bin/env bash
# endpoint-resolution: validate the product 0.9.22 `source.endpoint` resolution
# on the OTLP batch path (no cluster, no daemon, local release binary).
#
# 0.9.22 replaced the direct-parent lookup with one bounded walk up the parent
# chain (CODE_ATTRS_MAX_DEPTH = 8) resolving, in order: the nearest inbound HTTP
# route, then the OUTERMOST usable code.* frame, then the literal "unknown".
# The endpoint is hashed into the acknowledgment signature
# (type : service : endpoint : hash(template)), so every rule below decides
# which findings share an ack and which do not.
#
#   A  the ancestor walk       route two levels up, route beats frames, the
#                              depth bound, blank values skipped
#   B  the CLIENT skip         an outbound url.full is not an inbound route,
#                              but SERVER / unspecified kinds still count and
#                              http.route counts on any kind
#   C  outermost, not nearest  two entry points over one shared DAO keep
#                              distinct endpoints; a framework layer carrying
#                              code.* of its own wins, and they collide
#   D  code-frame spelling     the legacy code.namespace + code.function pair
#                              and the stable code.function.name must spell one
#                              origin identically, or an agent upgrade re-keys
#                              every acknowledgment on that frame
#
# Requires product >= 0.9.22: on 0.9.17 every A/C/D endpoint is "unknown" (or,
# for a blank route, three literal spaces) and every B endpoint names the
# third party. See README.md for the per-assertion 0.9.17 baseline.
set -euo pipefail

SCENARIO="endpoint-resolution"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="${SCRIPT_DIR}/fixtures"
mkdir -p "${TMP_DIR}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
BIN_VERSION="$("${PERF_SENTINEL_LOCAL_BIN}" --version | awk '{print $2}')"
step "Pre-flight"
ok "binary perf-sentinel ${BIN_VERSION}"

for fixture in ancestor-shapes agent-frames; do
  step "analyze ${fixture}.ndjson"
  "${PERF_SENTINEL_LOCAL_BIN}" analyze --input "${FIX}/${fixture}.ndjson" --format json \
    > "${TMP_DIR}/${fixture}.json" 2> "${TMP_DIR}/${fixture}.err" \
    || die "analyze failed on ${fixture}.ndjson: $(tail -2 "${TMP_DIR}/${fixture}.err")"
  ok "$(python3 -c "import json;print(len(json.load(open('${TMP_DIR}/${fixture}.json'))['findings']))") findings"
done

step "Assertions"
set +e
python3 - "${TMP_DIR}/ancestor-shapes.json" "${TMP_DIR}/agent-frames.json" "${REPORT}" <<'PY'
import json
import sys

shapes_path, frames_path, report_path = sys.argv[1], sys.argv[2], sys.argv[3]


def endpoints(path, prefix):
    """service -> source_endpoint, one n_plus_one_sql per fixture trace."""
    out = {}
    for f in json.load(open(path))["findings"]:
        svc = f["service"]
        assert svc.startswith(prefix), f"unexpected service {svc}"
        key = svc[len(prefix):]
        assert key not in out, f"{svc} produced more than one finding"
        out[key] = f["source_endpoint"]
    return out


shapes = endpoints(shapes_path, "shape-")
frames = endpoints(frames_path, "frame-")
rows, failures = [], 0


def check(tid, desc, actual, expected):
    global failures
    passed = actual == expected
    if not passed:
        failures += 1
    rows.append((tid, passed, desc, actual, expected))
    mark = "\033[32m    ok\033[0m" if passed else "\033[31m  FAIL\033[0m"
    detail = f"{actual!r}" if passed else f"got {actual!r}, want {expected!r}"
    print(f"{mark}  {tid:5s} {desc}: {detail}")


# --- A. the ancestor walk ---------------------------------------------------
check("A1", "route two levels above the leaf",
      shapes.get("route-two-levels-up"), "/api/orders")
check("A2", "a route outranks the code frames below it",
      shapes.get("route-above-frames"), "/api/orders")
check("A3", "a route at the depth bound is still found",
      shapes.get("route-at-depth-limit"), "/api/at-limit")
check("A4", "a route past the depth bound is not",
      shapes.get("route-past-depth-limit"), "unknown")
check("A5", "a blank http.route is skipped, not adopted",
      shapes.get("blank-route-then-frame"), "com.shop.PurgeJob.run")

# --- B. the CLIENT skip -----------------------------------------------------
check("B1", "url.full on a CLIENT ancestor is not an inbound route",
      shapes.get("client-url-ancestor"), "unknown")
check("B2", "url.full on a SERVER ancestor still counts",
      shapes.get("server-url-ancestor"), "https://shop.example/api/orders")
check("B3", "url.full on an unspecified kind still counts",
      shapes.get("unspecified-url-ancestor"), "https://shop.example/api/orders")
check("B4", "a route above a CLIENT ancestor wins",
      shapes.get("client-below-route"), "/api/checkout")
check("B5", "http.route counts on any kind, CLIENT included",
      shapes.get("route-on-client-span"), "/api/orders")

# --- C. outermost, not nearest ----------------------------------------------
check("C1", "entry point A names itself, not the shared DAO",
      shapes.get("app-entry-a"), "com.shop.OrderService.listOrders")
check("C2", "entry point B names itself, not the shared DAO",
      shapes.get("app-entry-b"), "com.shop.ReportService.monthlyReport")
check("C3", "two entry points over one statement stay distinct",
      shapes.get("app-entry-a") != shapes.get("app-entry-b"), True)
# "Outermost" means outermost usable APPLICATION frame. A framework layer that
# carries code.* of its own (Tomcat here) is skipped, so the entry point below
# it names the finding. Before that rule existed every entry point in a service
# collapsed onto the framework frame -- measured at 1799 Symfony and 1617
# Laravel findings sharing one kernel frame each.
check("C4", "a framework frame above the entry point is skipped",
      shapes.get("framework-above-entry-a"), "com.shop.OrderService.listOrders")
check("C5", "two entry points under one framework layer stay distinct",
      shapes.get("framework-above-entry-a") != shapes.get("framework-above-entry-b"),
      True)

# --- D. code-frame spelling -------------------------------------------------
# One origin, two agent spellings. They must produce one endpoint string: the
# ack signature hashes it, so a difference re-keys every acknowledgment
# recorded against that frame the day the agent is upgraded.
SPELLING_PAIRS = [
    ("D1", "PHP App\\Service\\OrderReporter::monthly",
     "php-app-legacy", "php-app-stable"),
    ("D3", "Java oteldemo.AdService.getAdsByCategory",
     "java-ad-legacy", "java-ad-stable"),
    ("D4", "Java com.perfsim.order.job.ScheduledJobs.reconcileOrders",
     "java-job-legacy", "java-job-stable"),
    ("D5", "Rust myapp::worker::run", "rust-legacy", "rust-stable"),
    ("D6", "Go github.com/shop/orders.(*Repo).FindAll", "go-legacy", "go-stable"),
    ("D7", "dotnet Shop.Orders.OrderRepository.FindAll",
     "dotnet-legacy", "dotnet-stable"),
    ("D8", "Python shop.orders.repo.find_all", "python-legacy", "python-stable"),
    ("D9", "Node OrderRepository.findAll", "node-legacy", "node-stable"),
]
for tid, desc, legacy_key, stable_key in SPELLING_PAIRS:
    legacy, stable = frames.get(legacy_key), frames.get(stable_key)
    check(tid, f"one spelling for {desc}", legacy, stable)

# Frames the resolver must refuse rather than mangle: strip_endpoint_secrets
# truncates at '?' and strips userinfo before the first '/', so an accepted
# `Order.valid?` would reach the ack signature as `Order.valid` and silently
# share it with the real `Order.valid`.
check("D10", "a '?' predicate frame yields unknown",
      frames.get("ruby-predicate"), "unknown")
check("D11", "the same frame without '?' resolves",
      frames.get("ruby-plain"), "Order.valid")
check("D12", "an '@' anonymous-class frame yields unknown",
      frames.get("php-anonymous-class"), "unknown")
check("D13", "'#' is rewritten to '.', not truncated",
      frames.get("hash-qualified"), "MyClass.method")
check("D14", "a bare unqualified function name yields unknown",
      frames.get("bare-function"), "unknown")
check("D15", "a blank namespace yields unknown, not a leading dot",
      frames.get("blank-namespace"), "unknown")

# --- E. framework frames name no origin ---------------------------------------
# A framework frame is not an entry point: adopting it produced an endpoint that
# looked resolved while colliding in the ack signature exactly as "unknown" did.
for tid, desc, key in [
    ("E1", "Symfony HttpKernel", "fw-symfony-kernel"),
    ("E2", "Laravel HTTP Kernel", "fw-laravel-kernel"),
    ("E3", "Doctrine DBAL statement", "fw-doctrine-stmt"),
    ("E4", "PDOStatement", "fw-pdo-statement"),
    ("E5", "Spring DispatcherServlet", "fw-spring-dispatcher"),
    ("E6", "Slim App", "php-slim-stable"),
    ("E7", "PHP-DI controller invoker", "php-invoker-stable"),
]:
    check(tid, f"{desc} is refused, not adopted", frames.get(key), "unknown")

# The list must anchor on a PREFIX. Substring matching would swallow these
# application-owned frames along with the frameworks they merely resemble.
for tid, desc, key, want in [
    ("E8", "an app package containing 'spring'", "near-springboard",
     "com.myshop.springboard.OrderJob.run"),
    ("E9", "an app package containing 'apache'", "near-apachecorp",
     "com.apachecorp.billing.Invoicer.emit"),
    ("E10", "a namespace starting with Illuminate but not the framework one",
     "near-illuminate", "IlluminateMetrics\\Collector::gather"),
]:
    check(tid, f"{desc} survives the prefix list", frames.get(key), want)

with open(report_path, "w", encoding="utf-8") as fh:
    fh.write("# Scenario report: endpoint-resolution\n\n")
    fh.write("Product 0.9.22 `source.endpoint` ancestor walk and code-frame "
             "fallback, OTLP batch path.\n\n")
    fh.write("| id | result | assertion | endpoint |\n|---|---|---|---|\n")
    for tid, passed, desc, actual, expected in rows:
        detail = f"`{actual}`" if passed else f"got `{actual}`, want `{expected}`"
        fh.write(f"| {tid} | {'PASS' if passed else 'FAIL'} | {desc} | {detail} |\n")
    fh.write(f"\n{len(rows) - failures}/{len(rows)} assertions passed.\n")

print(f"\n{len(rows) - failures}/{len(rows)} assertions passed")
sys.exit(1 if failures else 0)
PY
RC=$?
set -e

echo
if [ "${RC}" -eq 0 ]; then
  color_green "PASS — report at ${REPORT}"
else
  color_red "FAIL — report at ${REPORT}"
fi
exit "${RC}"
