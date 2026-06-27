# Idempotent schema + seed bootstrap, mirroring django-svc/schema.py.
# Creates the 3 tables in the `rails` schema and seeds 100 orders / 500 order
# items / 200 payments only when empty. A PostgreSQL advisory lock serializes
# the puma workers so they cannot double-seed.
module SchemaBootstrap
  ADVISORY_LOCK = 808_094 # unique per service (django uses 808191)

  module_function

  def run!
    conn = ActiveRecord::Base.connection
    conn.execute("SELECT pg_advisory_lock(#{ADVISORY_LOCK})")
    begin
      create_tables(conn)
      seed(conn) if conn.select_value("SELECT count(*) FROM orders").to_i.zero?
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK})")
    end
  end

  def create_tables(conn)
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS orders (
        id BIGSERIAL PRIMARY KEY,
        customer VARCHAR(255),
        status VARCHAR(32) DEFAULT 'PENDING',
        total_cents BIGINT DEFAULT 0,
        created_at TIMESTAMPTZ DEFAULT now()
      );
    SQL
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS order_items (
        id BIGSERIAL PRIMARY KEY,
        order_id BIGINT REFERENCES orders(id) ON DELETE CASCADE,
        sku VARCHAR(64),
        quantity INTEGER,
        price_cents BIGINT
      );
    SQL
    conn.execute("CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);")
    conn.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS payments (
        id BIGSERIAL PRIMARY KEY,
        order_id BIGINT,
        customer_id BIGINT,
        amount_cents BIGINT DEFAULT 0,
        status VARCHAR(32) DEFAULT 'AUTHORIZED',
        created_at TIMESTAMPTZ DEFAULT now()
      );
    SQL
    conn.execute("CREATE INDEX IF NOT EXISTS idx_payments_customer_id ON payments(customer_id);")
  end

  def seed(conn)
    conn.execute(<<~SQL)
      INSERT INTO orders (customer, status, total_cents)
        SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint
        FROM generate_series(1, 100) AS g;
    SQL
    conn.execute(<<~SQL)
      INSERT INTO order_items (order_id, sku, quantity, price_cents)
        SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint
        FROM orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100;
    SQL
    conn.execute(<<~SQL)
      INSERT INTO payments (order_id, customer_id, amount_cents, status)
        SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED'
        FROM generate_series(1, 200) AS g;
    SQL
  end
end
