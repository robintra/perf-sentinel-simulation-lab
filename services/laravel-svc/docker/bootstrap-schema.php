<?php
// Idempotent schema + seed bootstrap, mirroring rails-svc/lib/schema_bootstrap.rb.
// Creates the 3 tables in the `laravel` schema and seeds 100 orders / 500 order
// items / 200 payments only when empty. Guarded by a per-service PostgreSQL
// advisory lock so a future move to >1 replica cannot double-seed. Uses raw PDO
// (not Eloquent) so it stays independent of the Laravel bootstrap.
declare(strict_types=1);

$host   = getenv('DB_HOST') ?: 'localhost';
$port   = getenv('DB_PORT') ?: '5432';
$dbname = getenv('DB_NAME') ?: 'lab';
$user   = getenv('DB_USER') ?: 'laravel_user';
$pass   = getenv('DB_PASSWORD') ?: 'lab_laravel';
$schema = getenv('DB_SCHEMA') ?: 'laravel';
$lock   = 808095; // unique per service (rails uses 808094)

$dsn = "pgsql:host={$host};port={$port};dbname={$dbname};options=--search_path={$schema},public";

$pdo = null;
for ($attempt = 1; $attempt <= 60; $attempt++) {
    try {
        $pdo = new PDO($dsn, $user, $pass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        break;
    } catch (Throwable $e) {
        if ($attempt === 60) {
            fwrite(STDERR, "laravel-svc: postgres not reachable: {$e->getMessage()}\n");
            exit(1);
        }
        sleep(2);
    }
}

$pdo->exec("SELECT pg_advisory_lock({$lock})");
try {
    $pdo->exec(<<<SQL
        CREATE TABLE IF NOT EXISTS orders (
          id BIGSERIAL PRIMARY KEY,
          customer VARCHAR(255),
          status VARCHAR(32) DEFAULT 'PENDING',
          total_cents BIGINT DEFAULT 0,
          created_at TIMESTAMPTZ DEFAULT now()
        );
    SQL);
    $pdo->exec(<<<SQL
        CREATE TABLE IF NOT EXISTS order_items (
          id BIGSERIAL PRIMARY KEY,
          order_id BIGINT REFERENCES orders(id) ON DELETE CASCADE,
          sku VARCHAR(64),
          quantity INTEGER,
          price_cents BIGINT
        );
    SQL);
    $pdo->exec("CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);");
    $pdo->exec(<<<SQL
        CREATE TABLE IF NOT EXISTS payments (
          id BIGSERIAL PRIMARY KEY,
          order_id BIGINT,
          customer_id BIGINT,
          amount_cents BIGINT DEFAULT 0,
          status VARCHAR(32) DEFAULT 'AUTHORIZED',
          created_at TIMESTAMPTZ DEFAULT now()
        );
    SQL);
    $pdo->exec("CREATE INDEX IF NOT EXISTS idx_payments_customer_id ON payments(customer_id);");

    $count = (int) $pdo->query("SELECT count(*) FROM orders")->fetchColumn();
    if ($count === 0) {
        $pdo->exec(<<<SQL
            INSERT INTO orders (customer, status, total_cents)
              SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
              FROM generate_series(1, 100) AS g;
        SQL);
        $pdo->exec(<<<SQL
            INSERT INTO order_items (order_id, sku, quantity, price_cents)
              SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint
              FROM orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100;
        SQL);
        $pdo->exec(<<<SQL
            INSERT INTO payments (order_id, customer_id, amount_cents, status)
              SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED'
              FROM generate_series(1, 200) AS g;
        SQL);
    }
} finally {
    $pdo->exec("SELECT pg_advisory_unlock({$lock})");
}

fwrite(STDOUT, "laravel-svc: schema ready in {$schema}\n");
