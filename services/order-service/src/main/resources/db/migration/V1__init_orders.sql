CREATE TABLE IF NOT EXISTS orders.orders (
    id           BIGSERIAL PRIMARY KEY,
    customer     VARCHAR(255) NOT NULL,
    status       VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
    total_cents  BIGINT       NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders.order_items (
    id          BIGSERIAL PRIMARY KEY,
    order_id    BIGINT       NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
    sku         VARCHAR(64)  NOT NULL,
    quantity    INTEGER      NOT NULL,
    price_cents BIGINT       NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON orders.order_items(order_id);

INSERT INTO orders.orders (customer, status, total_cents)
SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
FROM generate_series(1, 100) AS g
ON CONFLICT DO NOTHING;

INSERT INTO orders.order_items (order_id, sku, quantity, price_cents)
SELECT
    o.id,
    'SKU-' || (o.id * 10 + g),
    (1 + (g % 5)),
    (100 + g * 50)::bigint
FROM orders.orders o
CROSS JOIN generate_series(1, 5) AS g
WHERE o.id <= 100;
