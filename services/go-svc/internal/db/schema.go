package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// EnsureSchema is the Go equivalent of the Flyway V1__init.sql used by
// the Java services. Idempotent: CREATE TABLE IF NOT EXISTS + the seed
// inserts are guarded by an existence probe. The `go` schema itself
// is owned by the postgres-multistack-schemas Job.
func EnsureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	const ddl = `
        CREATE TABLE IF NOT EXISTS "go".orders (
            id           BIGSERIAL PRIMARY KEY,
            customer     VARCHAR(255) NOT NULL,
            status       VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
            total_cents  BIGINT       NOT NULL DEFAULT 0,
            created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
        );
        CREATE TABLE IF NOT EXISTS "go".order_items (
            id          BIGSERIAL PRIMARY KEY,
            order_id    BIGINT       NOT NULL REFERENCES "go".orders(id) ON DELETE CASCADE,
            sku         VARCHAR(64)  NOT NULL,
            quantity    INTEGER      NOT NULL,
            price_cents BIGINT       NOT NULL
        );
        CREATE TABLE IF NOT EXISTS "go".payments (
            id           BIGSERIAL PRIMARY KEY,
            order_id     BIGINT       NOT NULL,
            customer_id  BIGINT       NOT NULL,
            amount_cents BIGINT       NOT NULL DEFAULT 0,
            status       VARCHAR(32)  NOT NULL DEFAULT 'AUTHORIZED',
            created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
        );
        CREATE INDEX IF NOT EXISTS idx_go_order_items_order_id ON "go".order_items(order_id);
        CREATE INDEX IF NOT EXISTS idx_go_payments_customer_id ON "go".payments(customer_id);
    `
	if _, err := pool.Exec(ctx, ddl); err != nil {
		return fmt.Errorf("ddl: %w", err)
	}

	var exists bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM "go".orders LIMIT 1)`).Scan(&exists); err != nil {
		return fmt.Errorf("seed probe: %w", err)
	}
	if exists {
		return nil
	}

	const seed = `
        INSERT INTO "go".orders (customer, status, total_cents)
        SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
        FROM generate_series(1, 100) AS g
        ON CONFLICT DO NOTHING;

        INSERT INTO "go".order_items (order_id, sku, quantity, price_cents)
        SELECT
            o.id,
            'SKU-' || (o.id * 10 + g),
            (1 + (g % 5)),
            (100 + g * 50)::bigint
        FROM "go".orders o
        CROSS JOIN generate_series(1, 5) AS g
        WHERE o.id <= 100;

        INSERT INTO "go".payments (order_id, customer_id, amount_cents, status)
        SELECT
            ((g - 1) % 100) + 1,
            ((g - 1) % 50) + 1,
            (g * 100)::bigint,
            'AUTHORIZED'
        FROM generate_series(1, 200) AS g;
    `
	if _, err := pool.Exec(ctx, seed); err != nil {
		return fmt.Errorf("seed: %w", err)
	}
	return nil
}
