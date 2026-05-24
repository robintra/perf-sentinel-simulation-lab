-- helidon-mp-svc schema. The schema itself is created by the
-- postgres-multistack-schemas Job; this migration owns the tables and
-- seed data.

CREATE TABLE IF NOT EXISTS helidon_mp.orders (
    id           BIGSERIAL PRIMARY KEY,
    customer     VARCHAR(255) NOT NULL,
    status       VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
    total_cents  BIGINT       NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS helidon_mp.order_items (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL REFERENCES helidon_mp.orders(id) ON DELETE CASCADE,
    sku         VARCHAR(64)  NOT NULL,
    quantity    INTEGER      NOT NULL,
    price_cents BIGINT       NOT NULL
);

CREATE TABLE IF NOT EXISTS helidon_mp.payments (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL,
    customer_id BIGINT       NOT NULL,
    amount_cents BIGINT      NOT NULL DEFAULT 0,
    status      VARCHAR(32)  NOT NULL DEFAULT 'AUTHORIZED',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_helidon_mp_order_items_order_id ON helidon_mp.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_helidon_mp_payments_customer_id ON helidon_mp.payments(customer_id);

INSERT INTO helidon_mp.orders (customer, status, total_cents)
SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
FROM generate_series(1, 100) AS g
ON CONFLICT DO NOTHING;

INSERT INTO helidon_mp.order_items (order_id, sku, quantity, price_cents)
SELECT
    o.id,
    'SKU-' || (o.id * 10 + g),
    (1 + (g % 5)),
    (100 + g * 50)::bigint
FROM helidon_mp.orders o
CROSS JOIN generate_series(1, 5) AS g
WHERE o.id <= 100;

INSERT INTO helidon_mp.payments (order_id, customer_id, amount_cents, status)
SELECT
    ((g - 1) % 100) + 1,
    ((g - 1) % 50) + 1,
    (g * 100)::bigint,
    'AUTHORIZED'
FROM generate_series(1, 200) AS g;
