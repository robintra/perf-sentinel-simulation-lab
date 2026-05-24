-- Quarkus stack: schema `quarkus`. The CREATE SCHEMA is owned by the
-- postgres-multistack-schemas Job, this migration only owns the table
-- shape and the seed data.
--
-- Three tables mirror the Java baseline (orders + items + payments)
-- so the 10 fault endpoints can hit consistent query shapes across
-- every multistack service. Seed counts match docs/MULTISTACK.md
-- minimums: 100 orders, 500 items, 200 payments.

CREATE TABLE IF NOT EXISTS quarkus.orders (
    id           BIGSERIAL PRIMARY KEY,
    customer     VARCHAR(255) NOT NULL,
    status       VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
    total_cents  BIGINT       NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS quarkus.order_items (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL REFERENCES quarkus.orders(id) ON DELETE CASCADE,
    sku         VARCHAR(64)  NOT NULL,
    quantity    INTEGER      NOT NULL,
    price_cents BIGINT       NOT NULL
);

CREATE TABLE IF NOT EXISTS quarkus.payments (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL,
    customer_id BIGINT       NOT NULL,
    amount_cents BIGINT      NOT NULL DEFAULT 0,
    status      VARCHAR(32)  NOT NULL DEFAULT 'AUTHORIZED',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quarkus_order_items_order_id ON quarkus.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_quarkus_payments_customer_id ON quarkus.payments(customer_id);

INSERT INTO quarkus.orders (customer, status, total_cents)
SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
FROM generate_series(1, 100) AS g
ON CONFLICT DO NOTHING;

INSERT INTO quarkus.order_items (order_id, sku, quantity, price_cents)
SELECT
    o.id,
    'SKU-' || (o.id * 10 + g),
    (1 + (g % 5)),
    (100 + g * 50)::bigint
FROM quarkus.orders o
CROSS JOIN generate_series(1, 5) AS g
WHERE o.id <= 100;

INSERT INTO quarkus.payments (order_id, customer_id, amount_cents, status)
SELECT
    ((g - 1) % 100) + 1,
    ((g - 1) % 50) + 1,
    (g * 100)::bigint,
    'AUTHORIZED'
FROM generate_series(1, 200) AS g;
