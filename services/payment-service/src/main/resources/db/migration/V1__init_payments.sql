CREATE TABLE IF NOT EXISTS payments.payments (
    id            BIGSERIAL PRIMARY KEY,
    order_id      BIGINT       NOT NULL,
    customer_id   BIGINT       NOT NULL,
    amount_cents  BIGINT       NOT NULL,
    status        VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payments_customer_id ON payments.payments(customer_id);
CREATE INDEX IF NOT EXISTS idx_payments_order_id ON payments.payments(order_id);

INSERT INTO payments.payments (order_id, customer_id, amount_cents, status)
SELECT g, ((g - 1) % 25) + 1, (g * 1000)::bigint, 'PAID'
FROM generate_series(1, 200) AS g
ON CONFLICT DO NOTHING;
