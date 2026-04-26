CREATE TABLE IF NOT EXISTS notifications.notifications (
    id           BIGSERIAL PRIMARY KEY,
    payment_id   BIGINT       NOT NULL,
    customer_id  BIGINT       NOT NULL,
    channel      VARCHAR(32)  NOT NULL DEFAULT 'EMAIL',
    message      TEXT         NOT NULL,
    sent_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_customer_id ON notifications.notifications(customer_id);
