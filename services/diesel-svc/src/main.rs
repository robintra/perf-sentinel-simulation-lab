// diesel-svc — Rust + Diesel 2.x sync + axum + reqwest multistack member.
// OTel instrumentation:
//   SERVER spans: axum-tracing-opentelemetry (http.route, http.request.method)
//   CLIENT spans: reqwest-tracing (http.request.method, url.full)
//   SQL spans:    manual tracing::info_span! with db.system + db.statement

use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
};
use axum_tracing_opentelemetry::middleware::{OtelAxumLayer, OtelInResponseLayer};
use diesel::prelude::*;
use diesel::r2d2::{ConnectionManager, Pool};
use opentelemetry::{global, trace::TracerProvider};
use opentelemetry_otlp::SpanExporter;
use opentelemetry_sdk::trace::SdkTracerProvider;
use reqwest_middleware::{ClientBuilder, ClientWithMiddleware};
use reqwest_tracing::TracingMiddleware;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{env, net::SocketAddr, time::Instant};
use tracing_opentelemetry::OpenTelemetryLayer;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

type PgPool = Pool<ConnectionManager<PgConnection>>;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    http: ClientWithMiddleware,
    self_base: String,
}

const SERVICE: &str = "diesel-svc";
const CHANNELS: &[&str] = &["email", "sms", "push", "webhook", "slack", "teams"];

// === DB span helper ========================================================

fn db_exec(conn: &mut PgConnection, sql: &str) -> diesel::QueryResult<usize> {
    let _span = tracing::info_span!("db.query",
        db.system = "postgresql",
        db.statement = %sql,
        otel.kind = "CLIENT",
    ).entered();
    diesel::sql_query(sql).execute(conn)
}

fn db_count(conn: &mut PgConnection, sql: &str) -> i64 {
    let _span = tracing::info_span!("db.query",
        db.system = "postgresql",
        db.statement = %sql,
        otel.kind = "CLIENT",
    ).entered();
    diesel::sql_query(sql)
        .get_result::<CountRow>(conn)
        .map(|r| r.count)
        .unwrap_or(0)
}

// === main ==================================================================

// OTel provider initialized BEFORE tokio runtime starts so the
// reqwest-blocking-client used by the batch exporter's dedicated
// OS thread doesn't panic with "cannot start a runtime from within
// a runtime" (opentelemetry-rust#2400).
fn init_otel() -> SdkTracerProvider {
    let exporter = SpanExporter::builder().with_http().build()
        .expect("otlp http exporter");
    let resource = opentelemetry_sdk::Resource::builder()
        .with_service_name(env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| SERVICE.into()))
        .build();
    SdkTracerProvider::builder()
        .with_resource(resource)
        .with_batch_exporter(exporter)
        .build()
}

fn main() {
    let provider = init_otel();
    let tracer = provider.tracer(SERVICE);
    global::set_tracer_provider(provider.clone());

    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async_main(provider, tracer));
}

async fn async_main(provider: SdkTracerProvider, tracer: opentelemetry_sdk::trace::Tracer) {
    let port: u16 = env::var("HTTP_PORT").ok()
        .and_then(|v| v.parse().ok()).unwrap_or(8088);
    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://diesel_user:lab_diesel@postgres.db.svc.cluster.local:5432/lab".into());
    let self_base = env::var("SELF_BASE_URL")
        .unwrap_or_else(|_| format!("http://localhost:{}", port));

    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| "info,tower_http=debug,otel=debug".into()))
        .with(tracing_subscriber::fmt::layer().compact())
        .with(OpenTelemetryLayer::new(tracer))
        .init();

    // DB pool
    let manager = ConnectionManager::<PgConnection>::new(&db_url);
    let pool = Pool::builder().max_size(10).build(manager)
        .expect("r2d2 pool");

    {
        let conn = &mut pool.get().expect("bootstrap conn");
        diesel::sql_query("SET search_path TO diesel, public").execute(conn).ok();
        bootstrap_schema(conn);
    }

    // HTTP client with reqwest-tracing for CLIENT spans
    let raw_http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build().unwrap();
    let http = ClientBuilder::new(raw_http)
        .with(TracingMiddleware::default())
        .build();

    let state = AppState { pool, http, self_base };

    let app = Router::new()
        .route("/health/live", get(health_live))
        .route("/health/ready", get(health_ready))
        .route("/api/external/mock", get(mock))
        .route("/api/dispatch/{channel}", get(dispatch))
        .route("/api/payments/history", get(payments_history))
        .route("/api/fault/n-plus-one-sql", post(n_plus_one_sql))
        .route("/api/fault/n-plus-one-http", post(n_plus_one_http))
        .route("/api/fault/redundant-sql", post(redundant_sql))
        .route("/api/fault/redundant-http", post(redundant_http))
        .route("/api/fault/slow-sql", post(slow_sql))
        .route("/api/fault/slow-http", post(slow_http))
        .route("/api/fault/fanout", post(fanout))
        .route("/api/fault/chatty", post(chatty))
        .route("/api/fault/serialized", post(serialized))
        .route("/api/fault/pool-saturation", post(pool_saturation))
        // axum-tracing-opentelemetry layers for semantic SERVER spans
        .layer(OtelInResponseLayer::default())
        .layer(OtelAxumLayer::default())
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!("diesel-svc listening on {addr}");
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await.unwrap();

    provider.shutdown().ok();
}

async fn shutdown_signal() { tokio::signal::ctrl_c().await.ok(); }

// === schema bootstrap ======================================================

fn bootstrap_schema(conn: &mut PgConnection) {
    for ddl in [
        "CREATE TABLE IF NOT EXISTS diesel.orders (id BIGSERIAL PRIMARY KEY, customer VARCHAR(255) NOT NULL, status VARCHAR(32) NOT NULL DEFAULT 'PENDING', total_cents BIGINT NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        "CREATE TABLE IF NOT EXISTS diesel.order_items (id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL REFERENCES diesel.orders(id) ON DELETE CASCADE, sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL, price_cents BIGINT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS diesel.payments (id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL, customer_id BIGINT NOT NULL, amount_cents BIGINT NOT NULL DEFAULT 0, status VARCHAR(32) NOT NULL DEFAULT 'AUTHORIZED', created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        "CREATE INDEX IF NOT EXISTS idx_diesel_oi_oid ON diesel.order_items(order_id)",
        "CREATE INDEX IF NOT EXISTS idx_diesel_pay_cid ON diesel.payments(customer_id)",
    ] { diesel::sql_query(ddl).execute(conn).ok(); }

    let exists = diesel::sql_query("SELECT EXISTS(SELECT 1 FROM diesel.orders LIMIT 1)")
        .get_result::<ExistsRow>(conn).map(|r| r.exists).unwrap_or(false);
    if exists { return; }
    for seed in [
        "INSERT INTO diesel.orders (customer, status, total_cents) SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint FROM generate_series(1, 100) AS g",
        "INSERT INTO diesel.order_items (order_id, sku, quantity, price_cents) SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint FROM diesel.orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100",
        "INSERT INTO diesel.payments (order_id, customer_id, amount_cents, status) SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED' FROM generate_series(1, 200) AS g",
    ] { diesel::sql_query(seed).execute(conn).ok(); }
}

#[derive(QueryableByName)]
struct ExistsRow { #[diesel(sql_type = diesel::sql_types::Bool)] exists: bool }

#[derive(QueryableByName)]
struct CountRow { #[diesel(sql_type = diesel::sql_types::BigInt)] count: i64 }

#[derive(QueryableByName, Serialize)]
struct PaymentRow {
    #[diesel(sql_type = diesel::sql_types::BigInt)] id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)] order_id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)] customer_id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)] amount_cents: i64,
    #[diesel(sql_type = diesel::sql_types::Text)] status: String,
}

// === helpers ================================================================

fn envelope(anti_pattern: &str, start: Instant, details: Value) -> Json<Value> {
    Json(json!({
        "antiPattern": anti_pattern, "service": SERVICE,
        "durationMs": start.elapsed().as_millis() as u64,
        "details": details,
        "timestamp": chrono::Utc::now().to_rfc3339(),
    }))
}

async fn do_get(http: &ClientWithMiddleware, base: &str, path: &str) -> i32 {
    match http.get(format!("{}{}", base, path)).send().await {
        Ok(r) if r.status().is_success() => 1,
        _ => 0,
    }
}

#[derive(Deserialize)] struct MockParams { #[serde(rename = "delayMs", default)] delay_ms: u64, #[serde(default)] seq: i32, #[serde(default)] op: i32 }
#[derive(Deserialize)] struct DelayParams { #[serde(rename = "delayMs", default)] delay_ms: u64 }
#[derive(Deserialize)] struct PaymentsParams { #[serde(rename = "customerId", default = "d1")] customer_id: i64, #[serde(default = "d10")] limit: i64 }
fn d1() -> i64 { 1 } fn d10() -> i64 { 10 }
#[derive(Deserialize)] struct ItemsParams { #[serde(default = "d15")] items: i32 } fn d15() -> i32 { 15 }
#[derive(Deserialize)] struct RepeatsParams { #[serde(default = "d10i")] repeats: i32 } fn d10i() -> i32 { 10 }
#[derive(Deserialize)] struct SlowParams { #[serde(rename = "delayMs", default = "d600")] delay_ms: i64, #[serde(default = "d6")] repeats: i32 } fn d600() -> i64 { 600 } fn d6() -> i32 { 6 }
#[derive(Deserialize)] struct ConcurrencyParams { #[serde(default = "d20")] concurrency: usize } fn d20() -> usize { 20 }
#[derive(Deserialize)] struct RecipientsParams { #[serde(default = "d10i")] recipients: i32 }
#[derive(Deserialize)] struct WidthParams { #[serde(default = "d40")] width: usize } fn d40() -> usize { 40 }
#[derive(Deserialize)] struct CallsParams { #[serde(default = "d30")] calls: i32 } fn d30() -> i32 { 30 }
#[derive(Deserialize)] struct StepsParams { #[serde(default = "d6u")] steps: usize } fn d6u() -> usize { 6 }

// === health ================================================================

async fn health_live() -> Json<Value> { Json(json!({"status": "UP"})) }
async fn health_ready(State(s): State<AppState>) -> Result<Json<Value>, StatusCode> {
    let pool = s.pool.clone();
    tokio::task::spawn_blocking(move || {
        let conn = &mut pool.get().map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        diesel::sql_query("SELECT 1").execute(conn).map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        Ok(Json(json!({"status": "UP"})))
    }).await.map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
}

// === business ==============================================================

async fn mock(Query(p): Query<MockParams>) -> Json<Value> {
    if p.delay_ms > 0 { tokio::time::sleep(std::time::Duration::from_millis(p.delay_ms)).await; }
    Json(json!({"ok": true, "seq": p.seq, "op": p.op, "delayMs": p.delay_ms}))
}
async fn dispatch(Path(channel): Path<String>, Query(p): Query<DelayParams>) -> Result<Json<Value>, StatusCode> {
    if !CHANNELS.contains(&channel.as_str()) { return Err(StatusCode::NOT_FOUND); }
    if p.delay_ms > 0 { tokio::time::sleep(std::time::Duration::from_millis(p.delay_ms)).await; }
    Ok(Json(json!({"channel": channel, "dispatched": true, "delayMs": p.delay_ms})))
}
async fn payments_history(State(s): State<AppState>, Query(p): Query<PaymentsParams>) -> Json<Value> {
    let pool = s.pool.clone();
    let limit = p.limit.clamp(1, 100);
    let cid = p.customer_id;
    let rows = tokio::task::spawn_blocking(move || {
        let conn = &mut pool.get().expect("conn");
        diesel::sql_query("SET search_path TO diesel, public").execute(conn).ok();
        let sql = "SELECT id, order_id, customer_id, amount_cents, status FROM payments WHERE customer_id = $1 ORDER BY id LIMIT $2";
        let _span = tracing::info_span!("db.query", db.system = "postgresql", db.statement = %sql, otel.kind = "CLIENT").entered();
        diesel::sql_query(sql)
            .bind::<diesel::sql_types::BigInt, _>(cid)
            .bind::<diesel::sql_types::BigInt, _>(limit)
            .get_results::<PaymentRow>(conn).unwrap_or_default()
    }).await.unwrap_or_default();
    Json(json!(rows.iter().map(|r| json!([r.id, r.order_id, r.customer_id, r.amount_cents, r.status])).collect::<Vec<_>>()))
}

// === SQL faults ============================================================

async fn n_plus_one_sql(State(s): State<AppState>, Query(p): Query<ItemsParams>) -> Json<Value> {
    let start = Instant::now();
    let pool = s.pool.clone();
    let items = p.items;
    let total = tokio::task::spawn_blocking(move || {
        let conn = &mut pool.get().expect("conn");
        diesel::sql_query("SET search_path TO diesel, public").execute(conn).ok();
        let mut total = 0i64;
        for oid in 1..=items {
            let q = format!("SELECT count(*) FROM order_items WHERE order_id = {}", oid);
            total += db_count(conn, &q);
        }
        total
    }).await.unwrap_or(0);
    envelope("n_plus_one_sql", start, json!({"items": items, "orders_touched": items, "items_total": total}))
}

async fn redundant_sql(State(s): State<AppState>, Query(p): Query<RepeatsParams>) -> Json<Value> {
    let start = Instant::now();
    let pool = s.pool.clone();
    let repeats = p.repeats;
    let total = tokio::task::spawn_blocking(move || {
        let conn = &mut pool.get().expect("conn");
        diesel::sql_query("SET search_path TO diesel, public").execute(conn).ok();
        let mut total = 0i64;
        for _ in 0..repeats {
            total += db_count(conn, "SELECT count(*) FROM payments WHERE customer_id = 1");
        }
        total
    }).await.unwrap_or(0);
    envelope("redundant_sql", start, json!({"repeats": repeats, "queries_made": repeats, "rows_seen": total}))
}

async fn slow_sql(State(s): State<AppState>, Query(p): Query<SlowParams>) -> Json<Value> {
    let start = Instant::now();
    let pool = s.pool.clone();
    let (delay_ms, repeats) = (p.delay_ms, p.repeats);
    let executed = tokio::task::spawn_blocking(move || {
        let conn = &mut pool.get().expect("conn");
        let seconds = delay_ms as f64 / 1000.0;
        let mut executed = 0;
        for i in 0..repeats {
            let q = format!("SELECT pg_sleep({}), * FROM diesel.orders ORDER BY id OFFSET {} LIMIT 1", seconds, i);
            if db_exec(conn, &q).is_ok() { executed += 1; }
        }
        executed
    }).await.unwrap_or(0);
    envelope("slow_sql", start, json!({"delayMs": delay_ms, "repeats": repeats, "queries_executed": executed, "delay_ms": delay_ms}))
}

async fn pool_saturation(State(s): State<AppState>, Query(p): Query<ConcurrencyParams>) -> Json<Value> {
    let start = Instant::now();
    let n = p.concurrency;
    let mut handles = Vec::with_capacity(n);
    for _ in 0..n {
        let pool = s.pool.clone();
        handles.push(tokio::task::spawn_blocking(move || {
            let conn = &mut pool.get().ok()?;
            db_exec(conn, "SELECT pg_sleep(0.4)").ok()?;
            Some(1i32)
        }));
    }
    let mut completed = 0;
    for h in handles { if let Ok(Some(1)) = h.await { completed += 1; } }
    envelope("pool_saturation", start, json!({"concurrency": n, "tasks_launched": n, "tasks_completed": completed}))
}

// === HTTP faults ===========================================================

async fn n_plus_one_http(State(s): State<AppState>, Query(p): Query<RecipientsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for i in 0..p.recipients { ok += do_get(&s.http, &s.self_base, &format!("/api/external/mock?delayMs=0&seq={}&op=0", i)).await; }
    envelope("n_plus_one_http", start, json!({"recipients": p.recipients, "calls_made": p.recipients, "calls_ok": ok}))
}
async fn redundant_http(State(s): State<AppState>, Query(p): Query<RepeatsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for _ in 0..p.repeats { ok += do_get(&s.http, &s.self_base, "/api/payments/history?customerId=1&limit=10").await; }
    envelope("redundant_http", start, json!({"repeats": p.repeats, "calls_made": p.repeats, "calls_ok": ok}))
}
async fn slow_http(State(s): State<AppState>, Query(p): Query<SlowParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for i in 0..p.repeats { ok += do_get(&s.http, &s.self_base, &format!("/api/external/mock?delayMs={}&seq={}&op=0", p.delay_ms, i)).await; }
    envelope("slow_http", start, json!({"delayMs": p.delay_ms, "repeats": p.repeats, "calls_made": p.repeats, "calls_ok": ok, "delay_ms": p.delay_ms}))
}
async fn fanout(State(s): State<AppState>, Query(p): Query<WidthParams>) -> Json<Value> {
    let start = Instant::now();
    let mut handles = Vec::with_capacity(p.width);
    for i in 0..p.width {
        let http = s.http.clone();
        let base = s.self_base.clone();
        handles.push(tokio::spawn(async move { do_get(&http, &base, &format!("/api/external/mock?delayMs=10&seq={}&op=0", i)).await }));
    }
    let mut ok = 0;
    for h in handles { if let Ok(v) = h.await { ok += v; } }
    envelope("excessive_fanout", start, json!({"width": p.width, "children_launched": p.width, "children_ok": ok}))
}
async fn chatty(State(s): State<AppState>, Query(p): Query<CallsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for i in 0..p.calls { ok += do_get(&s.http, &s.self_base, &format!("/api/external/mock?delayMs=5&seq={}&op={}", i, i % 7)).await; }
    envelope("chatty_service", start, json!({"calls": p.calls, "calls_made": p.calls, "calls_ok": ok}))
}
async fn serialized(State(s): State<AppState>, Query(p): Query<StepsParams>) -> Json<Value> {
    let n = p.steps.min(CHANNELS.len());
    let start = Instant::now();
    let wc_start = Instant::now();
    let mut ok = 0;
    for i in 0..n { ok += do_get(&s.http, &s.self_base, &format!("/api/dispatch/{}?delayMs=80", CHANNELS[i])).await; }
    envelope("serialized_calls", start, json!({"steps": n, "steps_ok": ok, "wall_clock_ms": wc_start.elapsed().as_millis() as u64}))
}
