import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

import psycopg
import requests as http_requests
from django.db import connection
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_POST
from opentelemetry import context as otel_context

SERVICE = "django-svc"
CHANNELS = {"email", "sms", "push", "webhook", "slack", "teams"}
CHANNELS_LIST = ["email", "sms", "push", "webhook", "slack", "teams"]
SELF_BASE = os.environ.get("SELF_BASE_URL", "http://localhost:8091")
_executor = ThreadPoolExecutor(max_workers=40, thread_name_prefix="django-fault")


def _envelope(anti_pattern, start, details):
    return JsonResponse({
        "antiPattern": anti_pattern,
        "service": SERVICE,
        "durationMs": int((time.monotonic() - start) * 1000),
        "details": details,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


def _get(path):
    try:
        r = http_requests.get(f"{SELF_BASE}{path}", timeout=15)
        return 1 if r.status_code == 200 else 0
    except Exception:
        return 0


# === Health ================================================================

@require_GET
def health(_request):
    try:
        with connection.cursor() as cur:
            cur.execute("SELECT 1")
    except Exception:
        return JsonResponse({"status": "DOWN"}, status=503)
    return JsonResponse({"status": "UP"})


# === Business ==============================================================

@require_GET
def mock(request):
    delay_ms = int(request.GET.get("delayMs", "0") or "0")
    seq = int(request.GET.get("seq", "0") or "0")
    op = int(request.GET.get("op", "0") or "0")
    if delay_ms > 0:
        time.sleep(delay_ms / 1000)
    return JsonResponse({"ok": True, "seq": seq, "op": op, "delayMs": delay_ms})


@require_GET
def dispatch(request, channel):
    if channel not in CHANNELS:
        return JsonResponse({"error": "unknown channel"}, status=404)
    delay_ms = int(request.GET.get("delayMs", "0") or "0")
    if delay_ms > 0:
        time.sleep(delay_ms / 1000)
    return JsonResponse({"channel": channel, "dispatched": True, "delayMs": delay_ms})


@require_GET
def payments_history(request):
    customer_id = int(request.GET.get("customerId", "1") or "1")
    limit = max(1, min(int(request.GET.get("limit", "10") or "10"), 100))
    with connection.cursor() as cur:
        cur.execute(
            "SELECT id, order_id, customer_id, amount_cents, status "
            "FROM django.payments WHERE customer_id = %s ORDER BY id LIMIT %s",
            [customer_id, limit],
        )
        rows = cur.fetchall()
    return JsonResponse(list(rows), safe=False)


# === SQL faults ============================================================

@csrf_exempt
@require_POST
def n_plus_one_sql(request):
    items = int(request.GET.get("items", "15") or "15")
    start = time.monotonic()
    total = 0
    with connection.cursor() as cur:
        for order_id in range(1, items + 1):
            cur.execute(
                "SELECT count(*) FROM django.order_items WHERE order_id = %s",
                [order_id],
            )
            total += cur.fetchone()[0]
    return _envelope("n_plus_one_sql", start, {
        "items": items, "orders_touched": items, "items_total": total,
    })


@csrf_exempt
@require_POST
def redundant_sql(request):
    repeats = int(request.GET.get("repeats", "10") or "10")
    start = time.monotonic()
    total = 0
    with connection.cursor() as cur:
        for _ in range(repeats):
            cur.execute(
                "SELECT count(*) FROM django.payments WHERE customer_id = 1"
            )
            total += cur.fetchone()[0]
    return _envelope("redundant_sql", start, {
        "repeats": repeats, "queries_made": repeats, "rows_seen": total,
    })


@csrf_exempt
@require_POST
def slow_sql(request):
    delay_ms = int(request.GET.get("delayMs", "600") or "600")
    repeats = int(request.GET.get("repeats", "6") or "6")
    start = time.monotonic()
    seconds = delay_ms / 1000
    executed = 0
    with connection.cursor() as cur:
        for i in range(repeats):
            cur.execute(
                f"SELECT pg_sleep({seconds}), * FROM django.orders ORDER BY id OFFSET {i} LIMIT 1"
            )
            cur.fetchall()
            executed += 1
    return _envelope("slow_sql", start, {
        "delayMs": delay_ms, "repeats": repeats,
        "queries_executed": executed, "delay_ms": delay_ms,
    })


# Build a psycopg DSN from the same env vars Django uses, for the
# pool-saturation endpoint which needs independent connections (Django
# reuses one connection per thread, masking saturation from OTel).
def _pg_dsn():
    return (
        f"host={os.environ.get('DB_HOST', 'localhost')} "
        f"port={os.environ.get('DB_PORT', '5432')} "
        f"dbname={os.environ.get('DB_NAME', 'lab')} "
        f"user={os.environ.get('DB_USER', 'django_user')} "
        f"password={os.environ.get('DB_PASSWORD', 'lab_django')} "
        f"options='-csearch_path=django,public'"
    )


@csrf_exempt
@require_POST
def pool_saturation(request):
    concurrency = int(request.GET.get("concurrency", "20") or "20")
    start = time.monotonic()
    dsn = _pg_dsn()
    parent_ctx = otel_context.get_current()

    def _worker():
        token = otel_context.attach(parent_ctx)
        try:
            with psycopg.connect(dsn, autocommit=True) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT pg_sleep(0.4)")
            return 1
        except Exception:
            return 0
        finally:
            otel_context.detach(token)

    futures = [_executor.submit(_worker) for _ in range(concurrency)]
    completed = sum(f.result(timeout=30) for f in as_completed(futures))
    return _envelope("pool_saturation", start, {
        "concurrency": concurrency, "tasks_launched": concurrency,
        "tasks_completed": completed,
    })


# === HTTP faults ===========================================================

@csrf_exempt
@require_POST
def n_plus_one_http(request):
    recipients = int(request.GET.get("recipients", "10") or "10")
    start = time.monotonic()
    ok = sum(_get(f"/api/external/mock?delayMs=0&seq={i}&op=0") for i in range(recipients))
    return _envelope("n_plus_one_http", start, {
        "recipients": recipients, "calls_made": recipients, "calls_ok": ok,
    })


@csrf_exempt
@require_POST
def redundant_http(request):
    repeats = int(request.GET.get("repeats", "10") or "10")
    start = time.monotonic()
    ok = sum(_get("/api/payments/history?customerId=1&limit=10") for _ in range(repeats))
    return _envelope("redundant_http", start, {
        "repeats": repeats, "calls_made": repeats, "calls_ok": ok,
    })


@csrf_exempt
@require_POST
def slow_http(request):
    delay_ms = int(request.GET.get("delayMs", "600") or "600")
    repeats = int(request.GET.get("repeats", "6") or "6")
    start = time.monotonic()
    ok = sum(_get(f"/api/external/mock?delayMs={delay_ms}&seq={i}&op=0") for i in range(repeats))
    return _envelope("slow_http", start, {
        "delayMs": delay_ms, "repeats": repeats,
        "calls_made": repeats, "calls_ok": ok, "delay_ms": delay_ms,
    })


# === Messaging faults =====================================================

def _bounded_int(request, name, default, minimum, maximum):
    try:
        value = int(request.GET.get(name, str(default)) or str(default))
    except ValueError:
        return None
    return value if minimum <= value <= maximum else None


@csrf_exempt
@require_POST
def n_plus_one_messaging(request):
    messages = _bounded_int(request, "messages", 8, 5, 100)
    if request.GET.get("broker", "rabbitmq") != "rabbitmq" or messages is None:
        return JsonResponse({"error": "invalid messaging parameters"}, status=400)

    from djangosvc import messaging

    start = time.monotonic()
    details = messaging.publish_sequentially(messages)
    return _envelope("n_plus_one_messaging", start, details)


@csrf_exempt
@require_POST
def slow_messaging(request):
    delay_ms = _bounded_int(request, "delayMs", 600, 501, 5000)
    repeats = _bounded_int(request, "repeats", 3, 3, 20)
    if (
        request.GET.get("broker", "rabbitmq") != "rabbitmq"
        or delay_ms is None
        or repeats is None
    ):
        return JsonResponse({"error": "invalid messaging parameters"}, status=400)

    from djangosvc import messaging

    start = time.monotonic()
    details = messaging.publish_slowly(delay_ms, repeats)
    return _envelope("slow_messaging", start, details)


@csrf_exempt
@require_POST
def fanout(request):
    width = int(request.GET.get("width", "40") or "40")
    start = time.monotonic()
    # Capture the current OTel context (holds the SERVER span) so
    # worker threads can attach it — without this, the CLIENT spans
    # from _get() are orphans and the daemon cannot correlate the N
    # children with the parent request.
    parent_ctx = otel_context.get_current()

    def _get_with_ctx(path):
        token = otel_context.attach(parent_ctx)
        try:
            return _get(path)
        finally:
            otel_context.detach(token)

    futures = [
        _executor.submit(_get_with_ctx, f"/api/external/mock?delayMs=10&seq={i}&op=0")
        for i in range(width)
    ]
    ok = sum(f.result(timeout=30) for f in as_completed(futures))
    return _envelope("excessive_fanout", start, {
        "width": width, "children_launched": width, "children_ok": ok,
    })


@csrf_exempt
@require_POST
def chatty(request):
    calls = int(request.GET.get("calls", "30") or "30")
    start = time.monotonic()
    ok = sum(_get(f"/api/external/mock?delayMs=5&seq={i}&op={i % 7}") for i in range(calls))
    return _envelope("chatty_service", start, {
        "calls": calls, "calls_made": calls, "calls_ok": ok,
    })


@csrf_exempt
@require_POST
def serialized(request):
    steps = min(int(request.GET.get("steps", "6") or "6"), len(CHANNELS_LIST))
    start = time.monotonic()
    wc_start = time.monotonic()
    ok = sum(_get(f"/api/dispatch/{CHANNELS_LIST[i]}?delayMs=80") for i in range(steps))
    wall_clock_ms = int((time.monotonic() - wc_start) * 1000)
    return _envelope("serialized_calls", start, {
        "steps": steps, "steps_ok": ok, "wall_clock_ms": wall_clock_ms,
    })
