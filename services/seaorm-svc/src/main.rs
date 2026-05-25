// seaorm-svc — Rust + SeaORM 1.1 async + axum + reqwest multistack member.
// SeaORM is async-native (sqlx under the hood), so no spawn_blocking needed.
// OTel: same pattern as diesel-svc — reqwest-blocking-client pre-runtime,
// axum-tracing-opentelemetry SERVER spans, manual CLIENT + SQL spans.

use axum::{
    Router,
    extract::{Path, Query, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
};
use axum_tracing_opentelemetry::middleware::{OtelAxumLayer, OtelInResponseLayer};
use opentelemetry::{global, trace::TracerProvider};
use opentelemetry_otlp::SpanExporter;
use opentelemetry_sdk::trace::SdkTracerProvider;
use reqwest_middleware::{ClientBuilder, ClientWithMiddleware};
use reqwest_tracing::TracingMiddleware;
use sea_orm::{
    ConnectionTrait, Database, DatabaseConnection, DbBackend, Statement,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{env, net::SocketAddr, time::Instant};
use tracing::Instrument;
use tracing_opentelemetry::OpenTelemetryLayer;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[derive(Clone)]
struct AppState {
    db: DatabaseConnection,
    http: ClientWithMiddleware,
    self_base: String,
}

const SERVICE: &str = "seaorm-svc";
const CHANNELS: &[&str] = &["email", "sms", "push", "webhook", "slack", "teams"];

// === DB span helper (async, no spawn_blocking needed) ======================

async fn db_query_scalar(db: &DatabaseConnection, sql: &str) -> i64 {
    let span = tracing::info_span!("db.query",
        db.system = "postgresql", db.statement = %sql, otel.kind = "CLIENT");
    let result = db.query_one(Statement::from_string(DbBackend::Postgres, sql))
        .instrument(span).await;
    match result {
        Ok(Some(row)) => sea_orm::FromQueryResult::from_query_result(&row, "")
            .map(|r: CountResult| r.count).unwrap_or(0),
        _ => 0,
    }
}

async fn db_exec(db: &DatabaseConnection, sql: &str) -> bool {
    let span = tracing::info_span!("db.query",
        db.system = "postgresql", db.statement = %sql, otel.kind = "CLIENT");
    db.execute(Statement::from_string(DbBackend::Postgres, sql))
        .instrument(span).await.is_ok()
}

#[derive(Debug, sea_orm::FromQueryResult)]
struct CountResult { count: i64 }

#[derive(Debug, sea_orm::FromQueryResult)]
struct PaymentRow { id: i64, order_id: i64, customer_id: i64, amount_cents: i64, status: String }

// === HTTP span helper ======================================================

async fn do_get(http: &ClientWithMiddleware, base: &str, path: &str) -> i32 {
    let url = format!("{}{}", base, path);
    let span = tracing::info_span!("http.request",
        otel.kind = "CLIENT", http.request.method = "GET", url.full = %url);
    let result = http.get(&url).send().instrument(span).await;
    match result {
        Ok(r) if r.status().is_success() => 1,
        _ => 0,
    }
}

// === OTel init (before tokio runtime) ======================================

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
        .and_then(|v| v.parse().ok()).unwrap_or(8089);
    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://seaorm_user:lab_seaorm@postgres.db.svc.cluster.local:5432/lab?options=-csearch_path%3Dseaorm%2Cpublic".into());
    let self_base = env::var("SELF_BASE_URL")
        .unwrap_or_else(|_| format!("http://localhost:{}", port));

    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| "info".into()))
        .with(tracing_subscriber::fmt::layer().compact())
        .with(OpenTelemetryLayer::new(tracer))
        .init();

    // DB — search_path is set via the ?options= URL param (both in
    // helm values and the fallback URL above), so every sqlx pool
    // connection inherits it at the protocol level. No per-connection
    // SET needed.
    let db = Database::connect(&db_url).await.expect("sea-orm connect");
    bootstrap_schema(&db).await;

    // HTTP client
    let raw = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15)).build().unwrap();
    let http = ClientBuilder::new(raw).with(TracingMiddleware::default()).build();

    let state = AppState { db, http, self_base };

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
        .layer(OtelInResponseLayer::default())
        .layer(OtelAxumLayer::default())
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!("seaorm-svc listening on {addr}");
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(async { tokio::signal::ctrl_c().await.ok(); })
        .await.unwrap();
    provider.shutdown().ok();
}

// === schema bootstrap ======================================================

async fn bootstrap_schema(db: &DatabaseConnection) {
    // Advisory lock serialises concurrent replicas (same pattern as
    // django-svc / fastapi-svc).
    db.execute(Statement::from_string(DbBackend::Postgres,
        "SELECT pg_advisory_lock(808991)")).await.ok();

    for ddl in [
        "CREATE TABLE IF NOT EXISTS seaorm.orders (id BIGSERIAL PRIMARY KEY, customer VARCHAR(255) NOT NULL, status VARCHAR(32) NOT NULL DEFAULT 'PENDING', total_cents BIGINT NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        "CREATE TABLE IF NOT EXISTS seaorm.order_items (id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL REFERENCES seaorm.orders(id) ON DELETE CASCADE, sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL, price_cents BIGINT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS seaorm.payments (id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL, customer_id BIGINT NOT NULL, amount_cents BIGINT NOT NULL DEFAULT 0, status VARCHAR(32) NOT NULL DEFAULT 'AUTHORIZED', created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        "CREATE INDEX IF NOT EXISTS idx_seaorm_oi_oid ON seaorm.order_items(order_id)",
        "CREATE INDEX IF NOT EXISTS idx_seaorm_pay_cid ON seaorm.payments(customer_id)",
    ] { db.execute(Statement::from_string(DbBackend::Postgres, ddl)).await.ok(); }

    // Proper error propagation — don't swallow connection errors as
    // "not exists" which would cause duplicate seed inserts.
    let exists = match db.query_one(Statement::from_string(DbBackend::Postgres,
        "SELECT EXISTS(SELECT 1 FROM seaorm.orders LIMIT 1) AS exists")).await {
        Ok(Some(row)) => row.try_get::<bool>("", "exists").unwrap_or(false),
        Ok(None) => false,
        Err(e) => {
            tracing::warn!("schema probe failed, skipping seed: {e}");
            db.execute(Statement::from_string(DbBackend::Postgres,
                "SELECT pg_advisory_unlock(808991)")).await.ok();
            return;
        }
    };

    if !exists {
        for seed in [
            "INSERT INTO seaorm.orders (customer, status, total_cents) SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint FROM generate_series(1, 100) AS g",
            "INSERT INTO seaorm.order_items (order_id, sku, quantity, price_cents) SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint FROM seaorm.orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100",
            "INSERT INTO seaorm.payments (order_id, customer_id, amount_cents, status) SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED' FROM generate_series(1, 200) AS g",
        ] { db.execute(Statement::from_string(DbBackend::Postgres, seed)).await.ok(); }
    }

    db.execute(Statement::from_string(DbBackend::Postgres,
        "SELECT pg_advisory_unlock(808991)")).await.ok();
}

// === helpers ================================================================

fn envelope(anti_pattern: &str, start: Instant, details: Value) -> Json<Value> {
    Json(json!({
        "antiPattern": anti_pattern, "service": SERVICE,
        "durationMs": start.elapsed().as_millis() as u64,
        "details": details, "timestamp": chrono::Utc::now().to_rfc3339(),
    }))
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
    s.db.execute(Statement::from_string(DbBackend::Postgres, "SELECT 1"))
        .await.map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    Ok(Json(json!({"status": "UP"})))
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
    let limit = p.limit.clamp(1, 100);
    let sql = format!("SELECT id, order_id, customer_id, amount_cents, status FROM seaorm.payments WHERE customer_id = {} ORDER BY id LIMIT {}", p.customer_id, limit);
    let span = tracing::info_span!("db.query", db.system = "postgresql", db.statement = %sql, otel.kind = "CLIENT");
    let rows = s.db.query_all(Statement::from_string(DbBackend::Postgres, &sql))
        .instrument(span).await.unwrap_or_default();
    let arr: Vec<Value> = rows.iter().filter_map(|r| {
        Some(json!([
            r.try_get::<i64>("", "id").ok()?,
            r.try_get::<i64>("", "order_id").ok()?,
            r.try_get::<i64>("", "customer_id").ok()?,
            r.try_get::<i64>("", "amount_cents").ok()?,
            r.try_get::<String>("", "status").ok()?,
        ]))
    }).collect();
    Json(json!(arr))
}

// === SQL faults ============================================================

async fn n_plus_one_sql(State(s): State<AppState>, Query(p): Query<ItemsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut total = 0i64;
    for oid in 1..=p.items {
        total += db_query_scalar(&s.db, &format!("SELECT count(*) FROM seaorm.order_items WHERE order_id = {}", oid)).await;
    }
    envelope("n_plus_one_sql", start, json!({"items": p.items, "orders_touched": p.items, "items_total": total}))
}
async fn redundant_sql(State(s): State<AppState>, Query(p): Query<RepeatsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut total = 0i64;
    for _ in 0..p.repeats {
        total += db_query_scalar(&s.db, "SELECT count(*) FROM seaorm.payments WHERE customer_id = 1").await;
    }
    envelope("redundant_sql", start, json!({"repeats": p.repeats, "queries_made": p.repeats, "rows_seen": total}))
}
async fn slow_sql(State(s): State<AppState>, Query(p): Query<SlowParams>) -> Json<Value> {
    let start = Instant::now();
    let seconds = p.delay_ms as f64 / 1000.0;
    let mut executed = 0;
    for i in 0..p.repeats {
        if db_exec(&s.db, &format!("SELECT pg_sleep({}), * FROM seaorm.orders ORDER BY id OFFSET {} LIMIT 1", seconds, i)).await {
            executed += 1;
        }
    }
    envelope("slow_sql", start, json!({"delayMs": p.delay_ms, "repeats": p.repeats, "queries_executed": executed, "delay_ms": p.delay_ms}))
}
async fn pool_saturation(State(s): State<AppState>, Query(p): Query<ConcurrencyParams>) -> Json<Value> {
    let start = Instant::now();
    let parent = tracing::Span::current();
    let mut handles = Vec::with_capacity(p.concurrency);
    for _ in 0..p.concurrency {
        let db = s.db.clone();
        let p = parent.clone();
        handles.push(tokio::spawn(async move {
            db_exec(&db, "SELECT pg_sleep(0.4)").instrument(p).await as i32
        }));
    }
    let mut completed = 0;
    for h in handles { if let Ok(v) = h.await { completed += v; } }
    envelope("pool_saturation", start, json!({"concurrency": p.concurrency, "tasks_launched": p.concurrency, "tasks_completed": completed}))
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
    let parent = tracing::Span::current();
    let mut handles = Vec::with_capacity(p.width);
    for i in 0..p.width {
        let http = s.http.clone();
        let base = s.self_base.clone();
        handles.push(tokio::spawn(
            async move { do_get(&http, &base, &format!("/api/external/mock?delayMs=10&seq={}&op=0", i)).await }
                .instrument(parent.clone())
        ));
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
