using Microsoft.EntityFrameworkCore;

namespace DotnetSvc.Data;

/// <summary>
/// Idempotent bootstrap that creates the `dotnet` schema tables and
/// seeds them. Runs at startup, mirrors the Flyway V1__init.sql
/// pattern used by the Java services. Uses raw SQL (not EF Core
/// migrations) because the schema itself is owned by the
/// postgres-multistack-schemas Job and the lab service does not need
/// migration history.
/// </summary>
internal static class SchemaBootstrap
{
    public static async Task EnsureSchemaAsync(AppDbContext db)
    {
        await db.Database.ExecuteSqlRawAsync("""
            CREATE TABLE IF NOT EXISTS dotnet.orders (
                id           BIGSERIAL PRIMARY KEY,
                customer     VARCHAR(255) NOT NULL,
                status       VARCHAR(32)  NOT NULL DEFAULT 'PENDING',
                total_cents  BIGINT       NOT NULL DEFAULT 0,
                created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
            );
            CREATE TABLE IF NOT EXISTS dotnet.order_items (
                id          BIGSERIAL PRIMARY KEY,
                order_id    BIGINT       NOT NULL REFERENCES dotnet.orders(id) ON DELETE CASCADE,
                sku         VARCHAR(64)  NOT NULL,
                quantity    INTEGER      NOT NULL,
                price_cents BIGINT       NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dotnet.payments (
                id          BIGSERIAL PRIMARY KEY,
                order_id    BIGINT       NOT NULL,
                customer_id BIGINT       NOT NULL,
                amount_cents BIGINT      NOT NULL DEFAULT 0,
                status      VARCHAR(32)  NOT NULL DEFAULT 'AUTHORIZED',
                created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS idx_dotnet_order_items_order_id ON dotnet.order_items(order_id);
            CREATE INDEX IF NOT EXISTS idx_dotnet_payments_customer_id ON dotnet.payments(customer_id);
            """);

        long orderCount = await db.Orders.LongCountAsync();
        if (orderCount > 0)
        {
            return;
        }

        await db.Database.ExecuteSqlRawAsync("""
            INSERT INTO dotnet.orders (customer, status, total_cents)
            SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
            FROM generate_series(1, 100) AS g
            ON CONFLICT DO NOTHING;

            INSERT INTO dotnet.order_items (order_id, sku, quantity, price_cents)
            SELECT
                o.id,
                'SKU-' || (o.id * 10 + g),
                (1 + (g % 5)),
                (100 + g * 50)::bigint
            FROM dotnet.orders o
            CROSS JOIN generate_series(1, 5) AS g
            WHERE o.id <= 100;

            INSERT INTO dotnet.payments (order_id, customer_id, amount_cents, status)
            SELECT
                ((g - 1) % 100) + 1,
                ((g - 1) % 50) + 1,
                (g * 100)::bigint,
                'AUTHORIZED'
            FROM generate_series(1, 200) AS g;
            """);
    }
}
