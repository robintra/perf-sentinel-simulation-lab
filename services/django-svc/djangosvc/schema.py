"""Idempotent schema bootstrap. Same pattern as the other multistack
services: CREATE TABLE IF NOT EXISTS + seed 100 orders + 500 items +
200 payments. Uses Django's connection.cursor() for raw SQL.

A PostgreSQL advisory lock serialises concurrent gunicorn workers
(2 workers each call ensure_schema at startup) to prevent the
TOCTOU race where both see zero rows and double the seed inserts."""

from django.db import connection

_ADVISORY_LOCK_ID = 808191


def ensure_schema():
    with connection.cursor() as cur:
        cur.execute("SELECT pg_advisory_lock(%s)", [_ADVISORY_LOCK_ID])
        try:
            _bootstrap(cur)
        finally:
            cur.execute("SELECT pg_advisory_unlock(%s)", [_ADVISORY_LOCK_ID])


def _bootstrap(cur):
    cur.execute("""CREATE TABLE IF NOT EXISTS django.orders (
        id BIGSERIAL PRIMARY KEY, customer VARCHAR(255) NOT NULL,
        status VARCHAR(32) NOT NULL DEFAULT 'PENDING',
        total_cents BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())""")
    cur.execute("""CREATE TABLE IF NOT EXISTS django.order_items (
        id BIGSERIAL PRIMARY KEY,
        order_id BIGINT NOT NULL REFERENCES django.orders(id) ON DELETE CASCADE,
        sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL,
        price_cents BIGINT NOT NULL)""")
    cur.execute("""CREATE TABLE IF NOT EXISTS django.payments (
        id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL,
        customer_id BIGINT NOT NULL, amount_cents BIGINT NOT NULL DEFAULT 0,
        status VARCHAR(32) NOT NULL DEFAULT 'AUTHORIZED',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())""")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_django_oi_oid ON django.order_items(order_id)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_django_pay_cid ON django.payments(customer_id)")

    cur.execute("SELECT EXISTS(SELECT 1 FROM django.orders LIMIT 1)")
    if cur.fetchone()[0]:
        return

    cur.execute("""INSERT INTO django.orders (customer, status, total_cents)
        SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
        FROM generate_series(1, 100) AS g""")
    cur.execute("""INSERT INTO django.order_items (order_id, sku, quantity, price_cents)
        SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint
        FROM django.orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100""")
    cur.execute("""INSERT INTO django.payments (order_id, customer_id, amount_cents, status)
        SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED'
        FROM generate_series(1, 200) AS g""")
