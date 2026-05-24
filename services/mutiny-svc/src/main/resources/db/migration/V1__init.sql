-- mutiny-svc schema. Mirrors quarkus-svc's tables but lives in the
-- `mutiny` schema so the reactive PgPool queries land in isolation.
-- The schema itself is owned by the postgres-multistack-schemas Job.

CREATE TABLE IF NOT EXISTS mutiny.orders (
    id           BIGSERIAL PRIMARY KEY,
    customer     VARCHAR(255) NOT NULL,
    status       VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
    total_cents  BIGINT       NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS mutiny.order_items (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL REFERENCES mutiny.orders(id) ON DELETE CASCADE,
    sku         VARCHAR(64)  NOT NULL,
    quantity    INTEGER      NOT NULL,
    price_cents BIGINT       NOT NULL
);

CREATE TABLE IF NOT EXISTS mutiny.payments (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL,
    customer_id BIGINT       NOT NULL,
    amount_cents BIGINT      NOT NULL DEFAULT 0,
    status      VARCHAR(32)  NOT NULL DEFAULT 'AUTHORIZED',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mutiny_order_items_order_id ON mutiny.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_mutiny_payments_customer_id ON mutiny.payments(customer_id);

INSERT INTO mutiny.orders (customer, status, total_cents)
SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
FROM generate_series(1, 100) AS g
ON CONFLICT DO NOTHING;

INSERT INTO mutiny.order_items (order_id, sku, quantity, price_cents)
SELECT
    o.id,
    'SKU-' || (o.id * 10 + g),
    (1 + (g % 5)),
    (100 + g * 50)::bigint
FROM mutiny.orders o
CROSS JOIN generate_series(1, 5) AS g
WHERE o.id <= 100;

INSERT INTO mutiny.payments (order_id, customer_id, amount_cents, status)
SELECT
    ((g - 1) % 100) + 1,
    ((g - 1) % 50) + 1,
    (g * 100)::bigint,
    'AUTHORIZED'
FROM generate_series(1, 200) AS g;
