require "pg"

class FaultController < ApplicationController
  # === SQL faults (through ActiveRecord -> ActiveRecord scope) =============

  # N distinct ActiveRecord record loads, one per order id -> n_plus_one_sql.
  # This is THE endpoint the validation keys on. Loading records (not `.count`)
  # routes through ActiveRecord's `_query_by_sql`, which the OTel ActiveRecord
  # instrumentation wraps in a span under
  # `OpenTelemetry::Instrumentation::ActiveRecord` — the ORM marker the daemon
  # maps to suggested_fix.framework = ruby_active_record. (`.count` would only
  # produce an adapter-level PG span and miss the ActiveRecord scope.)
  def n_plus_one_sql
    items = (params[:items] || 15).to_i
    start = monotonic
    total = 0
    (1..items).each { |order_id| total += OrderItem.where(order_id: order_id).to_a.size }
    envelope("n_plus_one_sql", start, { items: items, orders_touched: items, items_total: total })
  end

  # The same ActiveRecord record load repeated with identical params ->
  # redundant_sql (also under the ActiveRecord scope).
  def redundant_sql
    repeats = (params[:repeats] || 10).to_i
    start = monotonic
    total = 0
    repeats.times { total += Payment.where(customer_id: 1).to_a.size }
    envelope("redundant_sql", start, { repeats: repeats, queries_made: repeats, rows_seen: total })
  end

  # find_by_sql also routes through `_query_by_sql` (ActiveRecord scope); a
  # leading pg_sleep makes each query slow -> slow_sql.
  def slow_sql
    delay_ms = (params[:delayMs] || 600).to_i
    repeats = (params[:repeats] || 6).to_i
    seconds = delay_ms / 1000.0
    start = monotonic
    executed = 0
    repeats.times do |i|
      Order.find_by_sql("SELECT pg_sleep(#{seconds}), orders.* FROM orders ORDER BY id OFFSET #{i} LIMIT 1")
      executed += 1
    end
    envelope("slow_sql", start, { delayMs: delay_ms, repeats: repeats, queries_executed: executed })
  end

  # pool-saturation deliberately bypasses ActiveRecord's connection pool and
  # opens independent raw `pg` connections (instrumented under the PG scope),
  # so the daemon sees genuinely overlapping SQL spans. OTel context is carried
  # into each worker thread so the CLIENT spans parent onto the request span.
  def pool_saturation
    concurrency = (params[:concurrency] || 20).to_i
    start = monotonic
    ctx = OpenTelemetry::Context.current
    threads = Array.new(concurrency) do
      Thread.new { OpenTelemetry::Context.with_current(ctx) { raw_pg_sleep(0.4) } }
    end
    completed = threads.sum(&:value)
    envelope("pool_saturation", start,
             { concurrency: concurrency, tasks_launched: concurrency, tasks_completed: completed })
  end

  # === HTTP faults (through Net::HTTP -> Net::HTTP scope) ==================

  def n_plus_one_http
    recipients = (params[:recipients] || 10).to_i
    start = monotonic
    ok = (0...recipients).sum { |i| http_get("/api/external/mock?delayMs=0&seq=#{i}&op=0") }
    envelope("n_plus_one_http", start, { recipients: recipients, calls_made: recipients, calls_ok: ok })
  end

  def redundant_http
    repeats = (params[:repeats] || 10).to_i
    start = monotonic
    ok = (0...repeats).sum { http_get("/api/payments/history?customerId=1&limit=10") }
    envelope("redundant_http", start, { repeats: repeats, calls_made: repeats, calls_ok: ok })
  end

  def slow_http
    delay_ms = (params[:delayMs] || 600).to_i
    repeats = (params[:repeats] || 6).to_i
    start = monotonic
    ok = (0...repeats).sum { |i| http_get("/api/external/mock?delayMs=#{delay_ms}&seq=#{i}&op=0") }
    envelope("slow_http", start, { delayMs: delay_ms, repeats: repeats, calls_made: repeats, calls_ok: ok })
  end

  # Many concurrent children off ONE request -> excessive_fanout. Context is
  # propagated into the threads so the CLIENT spans share the request trace.
  def fanout
    width = (params[:width] || 40).to_i
    start = monotonic
    ctx = OpenTelemetry::Context.current
    threads = (0...width).map do |i|
      Thread.new do
        OpenTelemetry::Context.with_current(ctx) { http_get("/api/external/mock?delayMs=10&seq=#{i}&op=0") }
      end
    end
    ok = threads.sum(&:value)
    envelope("excessive_fanout", start, { width: width, children_launched: width, children_ok: ok })
  end

  def chatty
    calls = (params[:calls] || 30).to_i
    start = monotonic
    ok = (0...calls).sum { |i| http_get("/api/external/mock?delayMs=5&seq=#{i}&op=#{i % 7}") }
    envelope("chatty_service", start, { calls: calls, calls_made: calls, calls_ok: ok })
  end

  def serialized
    steps = [(params[:steps] || 6).to_i, CHANNELS.length].min
    start = monotonic
    ok = (0...steps).sum { |i| http_get("/api/dispatch/#{CHANNELS[i]}?delayMs=80") }
    envelope("serialized_calls", start, { steps: steps, steps_ok: ok })
  end

  private

  def raw_pg_sleep(seconds)
    conn = PG.connect(
      host: ENV.fetch("DB_HOST", "localhost"),
      port: ENV.fetch("DB_PORT", "5432"),
      dbname: ENV.fetch("DB_NAME", "lab"),
      user: ENV.fetch("DB_USER", "rails_user"),
      password: ENV.fetch("DB_PASSWORD", "lab_rails"),
      options: "-csearch_path=rails,public",
    )
    conn.exec("SELECT pg_sleep(#{seconds})")
    conn.close
    1
  rescue StandardError
    0
  end
end
