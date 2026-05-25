"""fastapi-svc — FastAPI + SQLAlchemy async + asyncpg multistack member.
OTel instrumentation: fastapi (SERVER spans), sqlalchemy (SQL spans),
httpx (CLIENT spans), asyncpg (low-level SQL). Port 8092."""

import asyncio
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse
from opentelemetry import context as otel_context, trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker

# === config ================================================================

SERVICE = "fastapi-svc"
DB_DSN = os.environ.get(
    "DATABASE_URL",
    "postgresql+asyncpg://fastapi_user:lab_fastapi@postgres.db.svc.cluster.local:5432/lab",
)
SELF_BASE = os.environ.get("SELF_BASE_URL", "http://localhost:8092")
CHANNELS = ["email", "sms", "push", "webhook", "slack", "teams"]
CHANNELS_SET = set(CHANNELS)

# === OTel ==================================================================

resource = Resource.create({"service.name": os.environ.get("OTEL_SERVICE_NAME", SERVICE)})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(), schedule_delay_millis=1000))
trace.set_tracer_provider(provider)

AsyncPGInstrumentor().instrument()
HTTPXClientInstrumentor().instrument()

# === DB ====================================================================

engine = create_async_engine(DB_DSN, pool_size=10, max_overflow=0,
                             connect_args={"timeout": 10})
SQLAlchemyInstrumentor().instrument(engine=engine.sync_engine)
async_session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

# === raw asyncpg pool (pool-saturation) ====================================

_raw_dsn = os.environ.get(
    "RAW_DATABASE_URL",
    "postgresql://fastapi_user:lab_fastapi@postgres.db.svc.cluster.local:5432/lab"
).replace("postgresql+asyncpg://", "postgresql://")

import asyncpg  # noqa: E402

_raw_pool = None


async def get_raw_pool():
    global _raw_pool
    if _raw_pool is None:
        _raw_pool = await asyncpg.create_pool(
            _raw_dsn, min_size=2, max_size=10,
            server_settings={"search_path": "fastapi,public"},
        )
    return _raw_pool


# === schema bootstrap ======================================================

async def ensure_schema():
    async with engine.begin() as conn:
        await conn.execute(text("SET search_path TO fastapi, public"))
        for ddl in [
            """CREATE TABLE IF NOT EXISTS fastapi.orders (
                id BIGSERIAL PRIMARY KEY, customer VARCHAR(255) NOT NULL,
                status VARCHAR(32) NOT NULL DEFAULT 'PENDING',
                total_cents BIGINT NOT NULL DEFAULT 0,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now())""",
            """CREATE TABLE IF NOT EXISTS fastapi.order_items (
                id BIGSERIAL PRIMARY KEY,
                order_id BIGINT NOT NULL REFERENCES fastapi.orders(id) ON DELETE CASCADE,
                sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL,
                price_cents BIGINT NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS fastapi.payments (
                id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL,
                customer_id BIGINT NOT NULL, amount_cents BIGINT NOT NULL DEFAULT 0,
                status VARCHAR(32) NOT NULL DEFAULT 'AUTHORIZED',
                created_at TIMESTAMPTZ NOT NULL DEFAULT now())""",
            "CREATE INDEX IF NOT EXISTS idx_fastapi_oi_oid ON fastapi.order_items(order_id)",
            "CREATE INDEX IF NOT EXISTS idx_fastapi_pay_cid ON fastapi.payments(customer_id)",
        ]:
            await conn.execute(text(ddl))

        row = await conn.execute(text("SELECT EXISTS(SELECT 1 FROM fastapi.orders LIMIT 1)"))
        if row.scalar():
            return

        await conn.execute(text("""INSERT INTO fastapi.orders (customer, status, total_cents)
            SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
            FROM generate_series(1, 100) AS g"""))
        await conn.execute(text("""INSERT INTO fastapi.order_items (order_id, sku, quantity, price_cents)
            SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint
            FROM fastapi.orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100"""))
        await conn.execute(text("""INSERT INTO fastapi.payments (order_id, customer_id, amount_cents, status)
            SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED'
            FROM generate_series(1, 200) AS g"""))


# === app ===================================================================

@asynccontextmanager
async def lifespan(_app):
    import logging
    log = logging.getLogger("fastapi-svc")
    for attempt in range(5):
        try:
            await ensure_schema()
            break
        except Exception as e:
            if attempt < 4:
                log.warning("schema bootstrap attempt %d failed: %s, retrying in 3s", attempt + 1, e)
                await asyncio.sleep(3)
            else:
                log.warning("schema bootstrap failed after 5 attempts: %s", e)
    yield
    await engine.dispose()
    pool = _raw_pool
    if pool:
        await pool.close()
    provider.shutdown()

app = FastAPI(lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)

_http = httpx.AsyncClient(base_url=SELF_BASE, timeout=15.0)


def _envelope(anti_pattern, start, details):
    return JSONResponse({
        "antiPattern": anti_pattern,
        "service": SERVICE,
        "durationMs": int((time.monotonic() - start) * 1000),
        "details": details,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


# === health ================================================================

@app.get("/health/live")
@app.get("/health/ready")
async def health():
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))
    return {"status": "UP"}


# === business ==============================================================

@app.get("/api/external/mock")
async def mock(delayMs: int = 0, seq: int = 0, op: int = 0):
    if delayMs > 0:
        await asyncio.sleep(delayMs / 1000)
    return {"ok": True, "seq": seq, "op": op, "delayMs": delayMs}


@app.get("/api/dispatch/{channel}")
async def dispatch(channel: str, delayMs: int = 0):
    if channel not in CHANNELS_SET:
        return JSONResponse({"error": "unknown channel"}, status_code=404)
    if delayMs > 0:
        await asyncio.sleep(delayMs / 1000)
    return {"channel": channel, "dispatched": True, "delayMs": delayMs}


@app.get("/api/payments/history")
async def payments_history(customerId: int = 1, limit: int = 10):
    safe = max(1, min(limit, 100))
    async with async_session() as s:
        await s.execute(text("SET search_path TO fastapi, public"))
        r = await s.execute(
            text("SELECT id, order_id, customer_id, amount_cents, status "
                 "FROM payments WHERE customer_id = :c ORDER BY id LIMIT :l"),
            {"c": customerId, "l": safe},
        )
        return [[row[0], row[1], row[2], row[3], row[4]] for row in r.fetchall()]


# === SQL faults ============================================================

@app.post("/api/fault/n-plus-one-sql")
async def n_plus_one_sql(items: int = 15):
    start = time.monotonic()
    total = 0
    async with async_session() as s:
        await s.execute(text("SET search_path TO fastapi, public"))
        for order_id in range(1, items + 1):
            r = await s.execute(
                text("SELECT count(*) FROM order_items WHERE order_id = :oid"),
                {"oid": order_id},
            )
            total += r.scalar()
    return _envelope("n_plus_one_sql", start, {
        "items": items, "orders_touched": items, "items_total": total,
    })


@app.post("/api/fault/redundant-sql")
async def redundant_sql(repeats: int = 10):
    start = time.monotonic()
    total = 0
    async with async_session() as s:
        await s.execute(text("SET search_path TO fastapi, public"))
        for _ in range(repeats):
            r = await s.execute(text("SELECT count(*) FROM payments WHERE customer_id = 1"))
            total += r.scalar()
    return _envelope("redundant_sql", start, {
        "repeats": repeats, "queries_made": repeats, "rows_seen": total,
    })


@app.post("/api/fault/slow-sql")
async def slow_sql(delayMs: int = 600, repeats: int = 6):
    start = time.monotonic()
    seconds = delayMs / 1000
    executed = 0
    async with async_session() as s:
        for i in range(repeats):
            await s.execute(text(
                f"SELECT pg_sleep({seconds}), * FROM fastapi.orders ORDER BY id OFFSET {i} LIMIT 1"
            ))
            executed += 1
    return _envelope("slow_sql", start, {
        "delayMs": delayMs, "repeats": repeats,
        "queries_executed": executed, "delay_ms": delayMs,
    })


@app.post("/api/fault/pool-saturation")
async def pool_saturation(concurrency: int = 20):
    start = time.monotonic()
    pool = await get_raw_pool()

    async def _worker():
        async with pool.acquire() as conn:
            await conn.execute("SELECT pg_sleep(0.4)")
        return 1

    results = await asyncio.gather(*[_worker() for _ in range(concurrency)], return_exceptions=True)
    completed = sum(1 for r in results if r == 1)
    return _envelope("pool_saturation", start, {
        "concurrency": concurrency, "tasks_launched": concurrency,
        "tasks_completed": completed,
    })


# === HTTP faults ===========================================================

async def _get(path):
    try:
        r = await _http.get(path)
        return 1 if r.status_code == 200 else 0
    except Exception:
        return 0


@app.post("/api/fault/n-plus-one-http")
async def n_plus_one_http(recipients: int = 10):
    start = time.monotonic()
    ok = 0
    for i in range(recipients):
        ok += await _get(f"/api/external/mock?delayMs=0&seq={i}&op=0")
    return _envelope("n_plus_one_http", start, {
        "recipients": recipients, "calls_made": recipients, "calls_ok": ok,
    })


@app.post("/api/fault/redundant-http")
async def redundant_http(repeats: int = 10):
    start = time.monotonic()
    ok = 0
    for _ in range(repeats):
        ok += await _get("/api/payments/history?customerId=1&limit=10")
    return _envelope("redundant_http", start, {
        "repeats": repeats, "calls_made": repeats, "calls_ok": ok,
    })


@app.post("/api/fault/slow-http")
async def slow_http(delayMs: int = 600, repeats: int = 6):
    start = time.monotonic()
    ok = 0
    for i in range(repeats):
        ok += await _get(f"/api/external/mock?delayMs={delayMs}&seq={i}&op=0")
    return _envelope("slow_http", start, {
        "delayMs": delayMs, "repeats": repeats,
        "calls_made": repeats, "calls_ok": ok, "delay_ms": delayMs,
    })


@app.post("/api/fault/fanout")
async def fanout(width: int = 40):
    start = time.monotonic()
    results = await asyncio.gather(
        *[_get(f"/api/external/mock?delayMs=10&seq={i}&op=0") for i in range(width)]
    )
    ok = sum(results)
    return _envelope("excessive_fanout", start, {
        "width": width, "children_launched": width, "children_ok": ok,
    })


@app.post("/api/fault/chatty")
async def chatty(calls: int = 30):
    start = time.monotonic()
    ok = 0
    for i in range(calls):
        ok += await _get(f"/api/external/mock?delayMs=5&seq={i}&op={i % 7}")
    return _envelope("chatty_service", start, {
        "calls": calls, "calls_made": calls, "calls_ok": ok,
    })


@app.post("/api/fault/serialized")
async def serialized(steps: int = 6):
    n = min(steps, len(CHANNELS))
    start = time.monotonic()
    wc_start = time.monotonic()
    ok = 0
    for i in range(n):
        ok += await _get(f"/api/dispatch/{CHANNELS[i]}?delayMs=80")
    wall_clock_ms = int((time.monotonic() - wc_start) * 1000)
    return _envelope("serialized_calls", start, {
        "steps": n, "steps_ok": ok, "wall_clock_ms": wall_clock_ms,
    })
