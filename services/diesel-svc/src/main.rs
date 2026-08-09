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
use lapin::{
    BasicProperties, Confirmation, Connection, ConnectionProperties, ExchangeKind,
    options::{
        BasicPublishOptions, ConfirmSelectOptions, ExchangeDeclareOptions, QueueBindOptions,
        QueueDeclareOptions,
    },
    types::{AMQPValue, FieldTable},
    uri::{AMQPAuthority, AMQPUri, AMQPUserInfo},
};
use opentelemetry::{
    KeyValue, global,
    trace::{Status, TracerProvider},
};
use opentelemetry_otlp::SpanExporter;
use opentelemetry_sdk::trace::SdkTracerProvider;
use reqwest_middleware::{ClientBuilder, ClientWithMiddleware};
use reqwest_tracing::TracingMiddleware;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    env,
    future::Future,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    time::{Duration, Instant},
};
use tracing::Instrument;
use tracing_opentelemetry::{OpenTelemetryLayer, OpenTelemetrySpanExt};
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
const MESSAGING_DESTINATION: &str = "perfsim.diesel-svc";
const MESSAGING_ROUTING_KEY: &str = "diesel-svc";
const CONFIRM_TIMEOUT_MS: u64 = 5_000;
const SESSION_SETUP_ROUND_TRIPS: u32 = 8;

type PublishFuture<'a> = Pin<Box<dyn Future<Output = Result<Value, String>> + Send + 'a>>;
type BoundaryFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;
type ConfirmationFuture = BoundaryFuture<'static, Result<PublishConfirmation, String>>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PublishConfirmation {
    Ack,
    Returned,
    Nack,
    NotRequested,
}

trait PublishSession: Send + Sync {
    fn publish<'a>(
        &'a self,
        payload: &'a [u8],
    ) -> BoundaryFuture<'a, Result<ConfirmationFuture, String>>;
    fn wait_for_confirms(&self) -> BoundaryFuture<'_, Result<PublishConfirmation, String>>;
    fn close(&self, timeout: Duration) -> BoundaryFuture<'_, Result<(), String>>;
}

struct LapinSession {
    connection: Connection,
    channel: lapin::Channel,
}

fn map_confirmation(confirmation: Confirmation) -> PublishConfirmation {
    match confirmation {
        Confirmation::Ack(None) => PublishConfirmation::Ack,
        Confirmation::Ack(Some(_)) => PublishConfirmation::Returned,
        Confirmation::Nack(_) => PublishConfirmation::Nack,
        Confirmation::NotRequested => PublishConfirmation::NotRequested,
    }
}

impl PublishSession for LapinSession {
    fn publish<'a>(
        &'a self,
        payload: &'a [u8],
    ) -> BoundaryFuture<'a, Result<ConfirmationFuture, String>> {
        Box::pin(async move {
            let confirmation = self
                .channel
                .basic_publish(
                    MESSAGING_DESTINATION.into(),
                    MESSAGING_ROUTING_KEY.into(),
                    BasicPublishOptions {
                        mandatory: true,
                        ..Default::default()
                    },
                    payload,
                    BasicProperties::default().with_delivery_mode(2),
                )
                .await
                .map_err(|error| error.to_string())?;
            Ok(Box::pin(async move {
                confirmation
                    .await
                    .map(map_confirmation)
                    .map_err(|error| error.to_string())
            }) as ConfirmationFuture)
        })
    }

    fn wait_for_confirms(&self) -> BoundaryFuture<'_, Result<PublishConfirmation, String>> {
        Box::pin(async move {
            self.channel
                .wait_for_confirms()
                .await
                .map(|returned| {
                    if returned.is_empty() {
                        PublishConfirmation::Ack
                    } else {
                        PublishConfirmation::Returned
                    }
                })
                .map_err(|error| error.to_string())
        })
    }

    fn close(&self, timeout: Duration) -> BoundaryFuture<'_, Result<(), String>> {
        Box::pin(async move {
            let channel_result =
                tokio::time::timeout(timeout, self.channel.close(200, "done".into()))
                    .await
                    .map_err(|_| "RabbitMQ channel close timed out".to_string())
                    .and_then(|result| result.map_err(|error| error.to_string()));
            let connection_result =
                tokio::time::timeout(timeout, self.connection.close(200, "done".into()))
                    .await
                    .map_err(|_| "RabbitMQ connection close timed out".to_string())
                    .and_then(|result| result.map_err(|error| error.to_string()));
            channel_result.and(connection_result)
        })
    }
}

fn producer_span() -> tracing::Span {
    tracing::info_span!(
        "perfsim.diesel-svc send",
        otel.kind = "PRODUCER",
        messaging.system = "rabbitmq",
        messaging.destination.name = MESSAGING_DESTINATION,
        messaging.operation.type = "send",
    )
}

fn record_publish_error(spans: &[tracing::Span], error: &str) {
    for span in spans {
        span.add_event(
            "exception",
            vec![
                KeyValue::new("exception.type", "RabbitMqPublishError"),
                KeyValue::new("exception.message", error.to_owned()),
            ],
        );
        span.set_status(Status::error(error.to_owned()));
    }
}

fn confirmation_result(confirmation: PublishConfirmation) -> Result<(), String> {
    match confirmation {
        PublishConfirmation::Ack => Ok(()),
        PublishConfirmation::Returned => Err("RabbitMQ returned an unroutable message".into()),
        PublishConfirmation::Nack => Err("RabbitMQ rejected a message".into()),
        PublishConfirmation::NotRequested => Err("RabbitMQ did not confirm a message".into()),
    }
}

fn session_setup_timeout(operation_timeout: Duration) -> Duration {
    operation_timeout * SESSION_SETUP_ROUND_TRIPS
}

async fn publish_direct_session<S: PublishSession + ?Sized>(
    session: &S,
    count: i32,
    prefix: &str,
    operation_timeout: Duration,
) -> Result<i32, String> {
    let mut spans = Vec::with_capacity(count as usize);
    let mut confirmations = Vec::with_capacity(count as usize);
    let mut publish_error = None;

    for index in 0..count {
        let payload = format!("{prefix}-{index}");
        let span = producer_span();
        let result = tokio::time::timeout(
            operation_timeout,
            session.publish(payload.as_bytes()).instrument(span.clone()),
        )
        .await
        .map_err(|_| "RabbitMQ basic_publish timed out".to_string())
        .and_then(|result| result);
        spans.push(span);
        match result {
            Ok(confirmation) => confirmations.push(confirmation),
            Err(error) => {
                record_publish_error(&spans, &error);
                publish_error = Some(error);
                break;
            }
        }
    }

    let result = if let Some(error) = publish_error {
        Err(error)
    } else {
        let grouped = tokio::time::timeout(operation_timeout, session.wait_for_confirms())
            .await
            .map_err(|_| "RabbitMQ group publisher confirm timed out".to_string())
            .and_then(|result| result)
            .and_then(confirmation_result);
        if let Err(error) = grouped {
            record_publish_error(&spans, &error);
            Err(error)
        } else {
            let mut first_error = None;
            for (span, confirmation) in spans.iter().zip(confirmations) {
                let outcome =
                    tokio::time::timeout(operation_timeout, confirmation.instrument(span.clone()))
                        .await
                        .map_err(|_| "RabbitMQ publisher confirmation timed out".to_string())
                        .and_then(|result| result)
                        .and_then(confirmation_result);
                if let Err(error) = outcome {
                    record_publish_error(std::slice::from_ref(span), &error);
                    first_error.get_or_insert(error);
                }
            }
            first_error.map_or(Ok(count), Err)
        }
    };

    let close_result = session.close(operation_timeout).await;
    result.and(close_result.map(|()| count))
}

async fn publish_slow_session<S: PublishSession + ?Sized>(
    session: &S,
    count: i32,
    prefix: &str,
    operation_timeout: Duration,
) -> Result<i32, String> {
    let mut result = Ok(count);
    for index in 0..count {
        let payload = format!("{prefix}-{index}");
        let span = producer_span();
        let outcome = match tokio::time::timeout(
            operation_timeout,
            session.publish(payload.as_bytes()).instrument(span.clone()),
        )
        .await
        .map_err(|_| "RabbitMQ basic_publish timed out".to_string())
        .and_then(|result| result)
        {
            Ok(confirmation) => {
                tokio::time::timeout(operation_timeout, confirmation.instrument(span.clone()))
                    .await
                    .map_err(|_| "RabbitMQ publisher confirmation timed out".to_string())
                    .and_then(|result| result)
                    .and_then(confirmation_result)
            }
            Err(error) => Err(error),
        };
        if let Err(error) = outcome {
            record_publish_error(std::slice::from_ref(&span), &error);
            result = Err(error);
            break;
        }
    }

    let close_result = session.close(operation_timeout).await;
    result.and(close_result.map(|()| count))
}

trait MessagingPublisher: Send + Sync {
    fn publish_sequentially(&self, messages: i32) -> PublishFuture<'_>;
    fn publish_slowly(&self, delay_ms: i64, repeats: i32) -> PublishFuture<'_>;
}

struct RabbitMqPublisher {
    direct_host: String,
    direct_port: u16,
    slow_host: String,
    slow_port: u16,
    toxiproxy_api: String,
    username: String,
    password: String,
    http: reqwest::Client,
}

impl RabbitMqPublisher {
    fn from_env() -> Self {
        Self {
            direct_host: env::var("RABBITMQ_HOST")
                .unwrap_or_else(|_| "rabbitmq.messaging.svc.cluster.local".into()),
            direct_port: env_u16("RABBITMQ_PORT", 5_672),
            slow_host: env::var("RABBITMQ_SLOW_HOST")
                .unwrap_or_else(|_| "toxiproxy.messaging.svc.cluster.local".into()),
            slow_port: env_u16("RABBITMQ_SLOW_PORT", 25_672),
            toxiproxy_api: env::var("TOXIPROXY_API")
                .unwrap_or_else(|_| "http://toxiproxy.messaging.svc.cluster.local:8474".into())
                .trim_end_matches('/')
                .into(),
            username: required_env("RABBITMQ_USERNAME"),
            password: required_env("RABBITMQ_PASSWORD"),
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(5))
                .timeout(Duration::from_secs(5))
                .build()
                .expect("messaging HTTP client"),
        }
    }

    fn uri(&self, host: &str, port: u16, timeout_ms: u64) -> AMQPUri {
        let mut uri = AMQPUri {
            authority: AMQPAuthority {
                userinfo: AMQPUserInfo {
                    username: self.username.clone(),
                    password: self.password.clone(),
                },
                host: host.into(),
                port,
            },
            ..Default::default()
        };
        uri.query.connection_timeout = Some(timeout_ms);
        uri
    }

    async fn update_latency(&self, delay_ms: i64) -> Result<(), String> {
        let update_url = format!(
            "{}/proxies/rabbitmq-slow/toxics/latency_downstream",
            self.toxiproxy_api,
        );
        let attributes = json!({"attributes": {"latency": delay_ms, "jitter": 0}});
        let mut response = self
            .http
            .post(&update_url)
            .json(&attributes)
            .send()
            .await
            .map_err(|error| error.to_string())?;
        if response.status() == StatusCode::NOT_FOUND {
            response = self
                .http
                .post(format!(
                    "{}/proxies/rabbitmq-slow/toxics",
                    self.toxiproxy_api
                ))
                .json(&json!({
                    "name": "latency_downstream",
                    "type": "latency",
                    "stream": "downstream",
                    "attributes": {"latency": delay_ms, "jitter": 0},
                }))
                .send()
                .await
                .map_err(|error| error.to_string())?;
            if response.status() == StatusCode::CONFLICT {
                response = self
                    .http
                    .post(&update_url)
                    .json(&attributes)
                    .send()
                    .await
                    .map_err(|error| error.to_string())?;
            }
        }
        response
            .error_for_status()
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    async fn open_session(
        &self,
        host: &str,
        port: u16,
        operation_timeout: Duration,
    ) -> Result<LapinSession, String> {
        tokio::time::timeout(session_setup_timeout(operation_timeout), async {
            let connection = Connection::connect_uri(
                self.uri(host, port, operation_timeout.as_millis() as u64),
                ConnectionProperties::default().with_connection_name(SERVICE.into()),
            )
            .await
            .map_err(|error| error.to_string())?;
            let channel = connection
                .create_channel()
                .await
                .map_err(|error| error.to_string())?;

            channel
                .exchange_declare(
                    MESSAGING_DESTINATION.into(),
                    ExchangeKind::Direct,
                    ExchangeDeclareOptions {
                        durable: true,
                        ..Default::default()
                    },
                    FieldTable::default(),
                )
                .await
                .map_err(|error| error.to_string())?;
            let mut arguments = FieldTable::default();
            arguments.insert("x-message-ttl".into(), AMQPValue::LongInt(60_000));
            channel
                .queue_declare(
                    MESSAGING_DESTINATION.into(),
                    QueueDeclareOptions {
                        durable: true,
                        ..Default::default()
                    },
                    arguments,
                )
                .await
                .map_err(|error| error.to_string())?;
            channel
                .queue_bind(
                    MESSAGING_DESTINATION.into(),
                    MESSAGING_DESTINATION.into(),
                    MESSAGING_ROUTING_KEY.into(),
                    QueueBindOptions::default(),
                    FieldTable::default(),
                )
                .await
                .map_err(|error| error.to_string())?;
            channel
                .confirm_select(ConfirmSelectOptions::default())
                .await
                .map_err(|error| error.to_string())?;
            Ok(LapinSession {
                connection,
                channel,
            })
        })
        .await
        .map_err(|_| "RabbitMQ session setup timed out".to_string())?
    }
}

impl MessagingPublisher for RabbitMqPublisher {
    fn publish_sequentially(&self, messages: i32) -> PublishFuture<'_> {
        Box::pin(async move {
            let operation_timeout = Duration::from_millis(CONFIRM_TIMEOUT_MS);
            let session = self
                .open_session(&self.direct_host, self.direct_port, operation_timeout)
                .await?;
            let confirmed =
                publish_direct_session(&session, messages, "diesel-message", operation_timeout)
                    .await?;
            Ok(json!({"published": messages, "confirmed": confirmed}))
        })
    }

    fn publish_slowly(&self, delay_ms: i64, repeats: i32) -> PublishFuture<'_> {
        Box::pin(async move {
            self.update_latency(delay_ms).await?;
            let operation_timeout = Duration::from_millis(delay_ms as u64 + CONFIRM_TIMEOUT_MS);
            let session = self
                .open_session(&self.slow_host, self.slow_port, operation_timeout)
                .await?;
            let confirmed =
                publish_slow_session(&session, repeats, "slow-diesel-message", operation_timeout)
                    .await?;
            Ok(json!({"published": repeats, "confirmed": confirmed, "delay_ms": delay_ms}))
        })
    }
}

fn env_u16(name: &str, default: u16) -> u16 {
    env::var(name).map_or(default, |value| {
        value
            .parse()
            .unwrap_or_else(|_| panic!("{name} must be a valid port"))
    })
}

fn required_env(name: &str) -> String {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| panic!("{name} is required"))
}

// === DB span helper ========================================================

fn db_exec(conn: &mut PgConnection, sql: &str) -> diesel::QueryResult<usize> {
    let _span = tracing::info_span!("db.query",
        db.system = "postgresql",
        db.statement = %sql,
        otel.kind = "CLIENT",
    )
    .entered();
    diesel::sql_query(sql).execute(conn)
}

fn db_count(conn: &mut PgConnection, sql: &str) -> i64 {
    let _span = tracing::info_span!("db.query",
        db.system = "postgresql",
        db.statement = %sql,
        otel.kind = "CLIENT",
    )
    .entered();
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
    let exporter = SpanExporter::builder()
        .with_http()
        .build()
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
    let port: u16 = env::var("HTTP_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8088);
    let db_url = env::var("DATABASE_URL").unwrap_or_else(|_| {
        "postgres://diesel_user:lab_diesel@postgres.db.svc.cluster.local:5432/lab".into()
    });
    let self_base =
        env::var("SELF_BASE_URL").unwrap_or_else(|_| format!("http://localhost:{}", port));

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,tower_http=debug,otel=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer().compact())
        .with(OpenTelemetryLayer::new(tracer))
        .init();

    // DB pool
    let manager = ConnectionManager::<PgConnection>::new(&db_url);
    let pool = Pool::builder()
        .max_size(10)
        .build(manager)
        .expect("r2d2 pool");

    {
        let conn = &mut pool.get().expect("bootstrap conn");
        diesel::sql_query("SET search_path TO diesel, public")
            .execute(conn)
            .ok();
        bootstrap_schema(conn);
    }

    // HTTP client with reqwest-tracing for CLIENT spans
    let raw_http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .unwrap();
    let http = ClientBuilder::new(raw_http)
        .with(TracingMiddleware::default())
        .build();

    let state = AppState {
        pool,
        http,
        self_base,
    };
    let messaging_publisher: Arc<dyn MessagingPublisher> = Arc::new(RabbitMqPublisher::from_env());

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
        .with_state(state)
        .merge(messaging_router(messaging_publisher))
        // axum-tracing-opentelemetry layers for semantic SERVER spans
        .layer(OtelInResponseLayer)
        .layer(OtelAxumLayer::default());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    tracing::info!("diesel-svc listening on {addr}");
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();

    provider.shutdown().ok();
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c().await.ok();
}

// === schema bootstrap ======================================================

fn bootstrap_schema(conn: &mut PgConnection) {
    for ddl in [
        "CREATE TABLE IF NOT EXISTS diesel.orders (id BIGSERIAL PRIMARY KEY, customer VARCHAR(255) NOT NULL, status VARCHAR(32) NOT NULL DEFAULT 'PENDING', total_cents BIGINT NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        "CREATE TABLE IF NOT EXISTS diesel.order_items (id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL REFERENCES diesel.orders(id) ON DELETE CASCADE, sku VARCHAR(64) NOT NULL, quantity INTEGER NOT NULL, price_cents BIGINT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS diesel.payments (id BIGSERIAL PRIMARY KEY, order_id BIGINT NOT NULL, customer_id BIGINT NOT NULL, amount_cents BIGINT NOT NULL DEFAULT 0, status VARCHAR(32) NOT NULL DEFAULT 'AUTHORIZED', created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        "CREATE INDEX IF NOT EXISTS idx_diesel_oi_oid ON diesel.order_items(order_id)",
        "CREATE INDEX IF NOT EXISTS idx_diesel_pay_cid ON diesel.payments(customer_id)",
    ] {
        diesel::sql_query(ddl).execute(conn).ok();
    }

    let exists = diesel::sql_query("SELECT EXISTS(SELECT 1 FROM diesel.orders LIMIT 1)")
        .get_result::<ExistsRow>(conn)
        .map(|r| r.exists)
        .unwrap_or(false);
    if exists {
        return;
    }
    for seed in [
        "INSERT INTO diesel.orders (customer, status, total_cents) SELECT 'customer-' || g, 'PENDING', (g * 1000)::bigint FROM generate_series(1, 100) AS g",
        "INSERT INTO diesel.order_items (order_id, sku, quantity, price_cents) SELECT o.id, 'SKU-' || (o.id * 10 + g), (1 + (g % 5)), (100 + g * 50)::bigint FROM diesel.orders o CROSS JOIN generate_series(1, 5) AS g WHERE o.id <= 100",
        "INSERT INTO diesel.payments (order_id, customer_id, amount_cents, status) SELECT ((g-1) % 100)+1, ((g-1) % 50)+1, (g * 100)::bigint, 'AUTHORIZED' FROM generate_series(1, 200) AS g",
    ] {
        diesel::sql_query(seed).execute(conn).ok();
    }
}

#[derive(QueryableByName)]
struct ExistsRow {
    #[diesel(sql_type = diesel::sql_types::Bool)]
    exists: bool,
}

#[derive(QueryableByName)]
struct CountRow {
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    count: i64,
}

#[derive(QueryableByName, Serialize)]
struct PaymentRow {
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    order_id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    customer_id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    amount_cents: i64,
    #[diesel(sql_type = diesel::sql_types::Text)]
    status: String,
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
    use tracing::Instrument;
    let url = format!("{}{}", base, path);
    let span = tracing::info_span!("http.request",
        otel.kind = "CLIENT",
        http.request.method = "GET",
        url.full = %url,
    );
    let result = http.get(&url).send().instrument(span).await;
    match result {
        Ok(r) if r.status().is_success() => 1,
        _ => 0,
    }
}

#[derive(Deserialize)]
struct MockParams {
    #[serde(rename = "delayMs", default)]
    delay_ms: u64,
    #[serde(default)]
    seq: i32,
    #[serde(default)]
    op: i32,
}
#[derive(Deserialize)]
struct DelayParams {
    #[serde(rename = "delayMs", default)]
    delay_ms: u64,
}
#[derive(Deserialize)]
struct PaymentsParams {
    #[serde(rename = "customerId", default = "d1")]
    customer_id: i64,
    #[serde(default = "d10")]
    limit: i64,
}
fn d1() -> i64 {
    1
}
fn d10() -> i64 {
    10
}
#[derive(Deserialize)]
struct ItemsParams {
    #[serde(default = "d15")]
    items: i32,
}
fn d15() -> i32 {
    15
}
#[derive(Deserialize)]
struct RepeatsParams {
    #[serde(default = "d10i")]
    repeats: i32,
}
fn d10i() -> i32 {
    10
}
#[derive(Deserialize)]
struct SlowParams {
    #[serde(rename = "delayMs", default = "d600")]
    delay_ms: i64,
    #[serde(default = "d6")]
    repeats: i32,
}
fn d600() -> i64 {
    600
}
fn d6() -> i32 {
    6
}
#[derive(Deserialize)]
struct ConcurrencyParams {
    #[serde(default = "d20")]
    concurrency: usize,
}
fn d20() -> usize {
    20
}
#[derive(Deserialize)]
struct RecipientsParams {
    #[serde(default = "d10i")]
    recipients: i32,
}
#[derive(Deserialize)]
struct WidthParams {
    #[serde(default = "d40")]
    width: usize,
}
fn d40() -> usize {
    40
}
#[derive(Deserialize)]
struct CallsParams {
    #[serde(default = "d30")]
    calls: i32,
}
fn d30() -> i32 {
    30
}
#[derive(Deserialize)]
struct StepsParams {
    #[serde(default = "d6u")]
    steps: usize,
}
fn d6u() -> usize {
    6
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NPlusOneMessagingParams {
    #[serde(default = "d8")]
    messages: i32,
    #[serde(default = "rabbitmq")]
    broker: String,
}
fn d8() -> i32 {
    8
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SlowMessagingParams {
    #[serde(rename = "delayMs", default = "d600")]
    delay_ms: i64,
    #[serde(default = "d3")]
    repeats: i32,
    #[serde(default = "rabbitmq")]
    broker: String,
}
fn d3() -> i32 {
    3
}
fn rabbitmq() -> String {
    "rabbitmq".into()
}

// === health ================================================================

async fn health_live() -> Json<Value> {
    Json(json!({"status": "UP"}))
}
async fn health_ready(State(s): State<AppState>) -> Result<Json<Value>, StatusCode> {
    let pool = s.pool.clone();
    tokio::task::spawn_blocking(move || {
        let conn = &mut pool.get().map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        diesel::sql_query("SELECT 1")
            .execute(conn)
            .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        Ok(Json(json!({"status": "UP"})))
    })
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
}

// === business ==============================================================

async fn mock(Query(p): Query<MockParams>) -> Json<Value> {
    if p.delay_ms > 0 {
        tokio::time::sleep(std::time::Duration::from_millis(p.delay_ms)).await;
    }
    Json(json!({"ok": true, "seq": p.seq, "op": p.op, "delayMs": p.delay_ms}))
}
async fn dispatch(
    Path(channel): Path<String>,
    Query(p): Query<DelayParams>,
) -> Result<Json<Value>, StatusCode> {
    if !CHANNELS.contains(&channel.as_str()) {
        return Err(StatusCode::NOT_FOUND);
    }
    if p.delay_ms > 0 {
        tokio::time::sleep(std::time::Duration::from_millis(p.delay_ms)).await;
    }
    Ok(Json(
        json!({"channel": channel, "dispatched": true, "delayMs": p.delay_ms}),
    ))
}
async fn payments_history(
    State(s): State<AppState>,
    Query(p): Query<PaymentsParams>,
) -> Json<Value> {
    let pool = s.pool.clone();
    let limit = p.limit.clamp(1, 100);
    let cid = p.customer_id;
    let parent = tracing::Span::current();
    let rows = tokio::task::spawn_blocking(move || {
        let _g = parent.entered();
        let conn = &mut pool.get().expect("conn");
        diesel::sql_query("SET search_path TO diesel, public").execute(conn).ok();
        let sql = "SELECT id, order_id, customer_id, amount_cents, status FROM payments WHERE customer_id = $1 ORDER BY id LIMIT $2";
        let _span = tracing::info_span!("db.query", db.system = "postgresql", db.statement = %sql, otel.kind = "CLIENT").entered();
        diesel::sql_query(sql)
            .bind::<diesel::sql_types::BigInt, _>(cid)
            .bind::<diesel::sql_types::BigInt, _>(limit)
            .get_results::<PaymentRow>(conn).unwrap_or_default()
    }).await.unwrap_or_default();
    Json(json!(
        rows.iter()
            .map(|r| json!([r.id, r.order_id, r.customer_id, r.amount_cents, r.status]))
            .collect::<Vec<_>>()
    ))
}

// === SQL faults ============================================================

async fn n_plus_one_sql(State(s): State<AppState>, Query(p): Query<ItemsParams>) -> Json<Value> {
    let start = Instant::now();
    let pool = s.pool.clone();
    let items = p.items;
    let parent = tracing::Span::current();
    let total = tokio::task::spawn_blocking(move || {
        let _g = parent.entered();
        let conn = &mut pool.get().expect("conn");
        diesel::sql_query("SET search_path TO diesel, public")
            .execute(conn)
            .ok();
        let mut total = 0i64;
        for oid in 1..=items {
            let q = format!("SELECT count(*) FROM order_items WHERE order_id = {}", oid);
            total += db_count(conn, &q);
        }
        total
    })
    .await
    .unwrap_or(0);
    envelope(
        "n_plus_one_sql",
        start,
        json!({"items": items, "orders_touched": items, "items_total": total}),
    )
}

async fn redundant_sql(State(s): State<AppState>, Query(p): Query<RepeatsParams>) -> Json<Value> {
    let start = Instant::now();
    let pool = s.pool.clone();
    let repeats = p.repeats;
    let parent = tracing::Span::current();
    let total = tokio::task::spawn_blocking(move || {
        let _g = parent.entered();
        let conn = &mut pool.get().expect("conn");
        diesel::sql_query("SET search_path TO diesel, public")
            .execute(conn)
            .ok();
        let mut total = 0i64;
        for _ in 0..repeats {
            total += db_count(conn, "SELECT count(*) FROM payments WHERE customer_id = 1");
        }
        total
    })
    .await
    .unwrap_or(0);
    envelope(
        "redundant_sql",
        start,
        json!({"repeats": repeats, "queries_made": repeats, "rows_seen": total}),
    )
}

async fn slow_sql(State(s): State<AppState>, Query(p): Query<SlowParams>) -> Json<Value> {
    let start = Instant::now();
    let pool = s.pool.clone();
    let (delay_ms, repeats) = (p.delay_ms, p.repeats);
    let parent = tracing::Span::current();
    let executed = tokio::task::spawn_blocking(move || {
        let _g = parent.entered();
        let conn = &mut pool.get().expect("conn");
        let seconds = delay_ms as f64 / 1000.0;
        let mut executed = 0;
        for i in 0..repeats {
            let q = format!(
                "SELECT pg_sleep({}), * FROM diesel.orders ORDER BY id OFFSET {} LIMIT 1",
                seconds, i
            );
            if db_exec(conn, &q).is_ok() {
                executed += 1;
            }
        }
        executed
    })
    .await
    .unwrap_or(0);
    envelope(
        "slow_sql",
        start,
        json!({"delayMs": delay_ms, "repeats": repeats, "queries_executed": executed, "delay_ms": delay_ms}),
    )
}

async fn pool_saturation(
    State(s): State<AppState>,
    Query(p): Query<ConcurrencyParams>,
) -> Json<Value> {
    let start = Instant::now();
    let n = p.concurrency;
    let mut handles = Vec::with_capacity(n);
    let parent = tracing::Span::current();
    for _ in 0..n {
        let pool = s.pool.clone();
        let p = parent.clone();
        handles.push(tokio::task::spawn_blocking(move || {
            let _g = p.entered();
            let conn = &mut pool.get().ok()?;
            db_exec(conn, "SELECT pg_sleep(0.4)").ok()?;
            Some(1i32)
        }));
    }
    let mut completed = 0;
    for h in handles {
        if let Ok(Some(1)) = h.await {
            completed += 1;
        }
    }
    envelope(
        "pool_saturation",
        start,
        json!({"concurrency": n, "tasks_launched": n, "tasks_completed": completed}),
    )
}

// === HTTP faults ===========================================================

async fn n_plus_one_http(
    State(s): State<AppState>,
    Query(p): Query<RecipientsParams>,
) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for i in 0..p.recipients {
        ok += do_get(
            &s.http,
            &s.self_base,
            &format!("/api/external/mock?delayMs=0&seq={}&op=0", i),
        )
        .await;
    }
    envelope(
        "n_plus_one_http",
        start,
        json!({"recipients": p.recipients, "calls_made": p.recipients, "calls_ok": ok}),
    )
}
async fn redundant_http(State(s): State<AppState>, Query(p): Query<RepeatsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for _ in 0..p.repeats {
        ok += do_get(
            &s.http,
            &s.self_base,
            "/api/payments/history?customerId=1&limit=10",
        )
        .await;
    }
    envelope(
        "redundant_http",
        start,
        json!({"repeats": p.repeats, "calls_made": p.repeats, "calls_ok": ok}),
    )
}
async fn slow_http(State(s): State<AppState>, Query(p): Query<SlowParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for i in 0..p.repeats {
        ok += do_get(
            &s.http,
            &s.self_base,
            &format!("/api/external/mock?delayMs={}&seq={}&op=0", p.delay_ms, i),
        )
        .await;
    }
    envelope(
        "slow_http",
        start,
        json!({"delayMs": p.delay_ms, "repeats": p.repeats, "calls_made": p.repeats, "calls_ok": ok, "delay_ms": p.delay_ms}),
    )
}
async fn fanout(State(s): State<AppState>, Query(p): Query<WidthParams>) -> Json<Value> {
    use tracing::Instrument;
    let start = Instant::now();
    let parent = tracing::Span::current();
    let mut handles = Vec::with_capacity(p.width);
    for i in 0..p.width {
        let http = s.http.clone();
        let base = s.self_base.clone();
        handles.push(tokio::spawn(
            async move {
                do_get(
                    &http,
                    &base,
                    &format!("/api/external/mock?delayMs=10&seq={}&op=0", i),
                )
                .await
            }
            .instrument(parent.clone()),
        ));
    }
    let mut ok = 0;
    for h in handles {
        if let Ok(v) = h.await {
            ok += v;
        }
    }
    envelope(
        "excessive_fanout",
        start,
        json!({"width": p.width, "children_launched": p.width, "children_ok": ok}),
    )
}
async fn chatty(State(s): State<AppState>, Query(p): Query<CallsParams>) -> Json<Value> {
    let start = Instant::now();
    let mut ok = 0;
    for i in 0..p.calls {
        ok += do_get(
            &s.http,
            &s.self_base,
            &format!("/api/external/mock?delayMs=5&seq={}&op={}", i, i % 7),
        )
        .await;
    }
    envelope(
        "chatty_service",
        start,
        json!({"calls": p.calls, "calls_made": p.calls, "calls_ok": ok}),
    )
}
async fn serialized(State(s): State<AppState>, Query(p): Query<StepsParams>) -> Json<Value> {
    let n = p.steps.min(CHANNELS.len());
    let start = Instant::now();
    let wc_start = Instant::now();
    let mut ok = 0;
    for channel in CHANNELS.iter().take(n) {
        ok += do_get(
            &s.http,
            &s.self_base,
            &format!("/api/dispatch/{channel}?delayMs=80"),
        )
        .await;
    }
    envelope(
        "serialized_calls",
        start,
        json!({"steps": n, "steps_ok": ok, "wall_clock_ms": wc_start.elapsed().as_millis() as u64}),
    )
}

// === Messaging faults =====================================================

fn messaging_router(publisher: Arc<dyn MessagingPublisher>) -> Router {
    Router::new()
        .route(
            "/api/fault/n-plus-one-messaging",
            post(n_plus_one_messaging),
        )
        .route("/api/fault/slow-messaging", post(slow_messaging))
        .with_state(publisher)
}

type MessagingResponse = Result<Json<Value>, (StatusCode, Json<Value>)>;

async fn n_plus_one_messaging(
    State(publisher): State<Arc<dyn MessagingPublisher>>,
    Query(params): Query<NPlusOneMessagingParams>,
) -> MessagingResponse {
    if params.broker != "rabbitmq" || !(5..=100).contains(&params.messages) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "invalid messaging parameters"})),
        ));
    }
    let start = Instant::now();
    let details = publisher
        .publish_sequentially(params.messages)
        .await
        .map_err(internal_messaging_error)?;
    Ok(envelope("n_plus_one_messaging", start, details))
}

async fn slow_messaging(
    State(publisher): State<Arc<dyn MessagingPublisher>>,
    Query(params): Query<SlowMessagingParams>,
) -> MessagingResponse {
    if params.broker != "rabbitmq"
        || !(501..=5_000).contains(&params.delay_ms)
        || !(3..=20).contains(&params.repeats)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "invalid messaging parameters"})),
        ));
    }
    let start = Instant::now();
    let details = publisher
        .publish_slowly(params.delay_ms, params.repeats)
        .await
        .map_err(internal_messaging_error)?;
    Ok(envelope("slow_messaging", start, details))
}

fn internal_messaging_error(error: String) -> (StatusCode, Json<Value>) {
    tracing::error!(%error, "messaging fault failed");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"error": "messaging fault failed"})),
    )
}

#[cfg(test)]
mod tests {
    use super::{
        BoundaryFuture, MessagingPublisher, PublishConfirmation, PublishFuture, PublishSession,
        messaging_router, publish_direct_session, publish_slow_session, session_setup_timeout,
    };
    use axum::{body::Body, http::Request};
    use opentelemetry::trace::{Status, TracerProvider};
    use opentelemetry_sdk::{
        error::OTelSdkResult,
        trace::{SdkTracerProvider, SpanData, SpanExporter},
    };
    use serde_json::json;
    use std::{
        collections::VecDeque,
        fmt,
        future::{Future, pending},
        process::Command,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };
    use tower::ServiceExt;
    use tracing_subscriber::layer::SubscriberExt;

    struct RecordingPublisher {
        calls: Arc<AtomicUsize>,
    }

    impl MessagingPublisher for RecordingPublisher {
        fn publish_sequentially(&self, messages: i32) -> PublishFuture<'_> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(async move { Ok(json!({"published": messages, "confirmed": messages})) })
        }

        fn publish_slowly(&self, delay_ms: i64, repeats: i32) -> PublishFuture<'_> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(async move {
                Ok(json!({"published": repeats, "confirmed": repeats, "delay_ms": delay_ms}))
            })
        }
    }

    #[derive(Clone)]
    enum FakeStep<T> {
        Ready(Result<T, String>),
        Pending,
    }

    struct FakeSession {
        calls: Arc<Mutex<Vec<String>>>,
        deferred: Mutex<VecDeque<FakeStep<()>>>,
        deferred_confirms: Mutex<VecDeque<FakeStep<PublishConfirmation>>>,
        grouped: Mutex<FakeStep<PublishConfirmation>>,
    }

    impl FakeSession {
        fn direct(steps: Vec<FakeStep<()>>, grouped: FakeStep<PublishConfirmation>) -> Self {
            let confirmations = vec![FakeStep::Ready(Ok(PublishConfirmation::Ack)); steps.len()];
            Self::direct_with_confirms(steps, confirmations, grouped)
        }

        fn direct_with_confirms(
            steps: Vec<FakeStep<()>>,
            confirmations: Vec<FakeStep<PublishConfirmation>>,
            grouped: FakeStep<PublishConfirmation>,
        ) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                deferred: Mutex::new(steps.into()),
                deferred_confirms: Mutex::new(confirmations.into()),
                grouped: Mutex::new(grouped),
            }
        }

        fn slow(steps: Vec<FakeStep<PublishConfirmation>>) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                deferred: Mutex::new(vec![FakeStep::Ready(Ok(())); steps.len()].into()),
                deferred_confirms: Mutex::new(steps.into()),
                grouped: Mutex::new(FakeStep::Ready(Ok(PublishConfirmation::Ack))),
            }
        }

        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    fn resolve_step<T: Send + 'static>(
        step: FakeStep<T>,
    ) -> BoundaryFuture<'static, Result<T, String>> {
        match step {
            FakeStep::Ready(result) => Box::pin(async move { result }),
            FakeStep::Pending => Box::pin(pending()),
        }
    }

    impl PublishSession for FakeSession {
        fn publish<'a>(
            &'a self,
            payload: &'a [u8],
        ) -> BoundaryFuture<'a, Result<super::ConfirmationFuture, String>> {
            let payload = String::from_utf8_lossy(payload).into_owned();
            self.calls
                .lock()
                .unwrap()
                .push(format!("publish:{payload}"));
            let publish = self.deferred.lock().unwrap().pop_front().unwrap();
            let confirm = self.deferred_confirms.lock().unwrap().pop_front().unwrap();
            let calls = self.calls.clone();
            Box::pin(async move {
                resolve_step(publish).await?;
                Ok(Box::pin(async move {
                    let result = resolve_step(confirm).await;
                    calls.lock().unwrap().push(format!("confirm:{payload}"));
                    result
                }) as super::ConfirmationFuture)
            })
        }

        fn wait_for_confirms(&self) -> BoundaryFuture<'_, Result<PublishConfirmation, String>> {
            self.calls.lock().unwrap().push("group_confirm".into());
            resolve_step(self.grouped.lock().unwrap().clone())
        }

        fn close(&self, _timeout: Duration) -> BoundaryFuture<'_, Result<(), String>> {
            self.calls.lock().unwrap().push("close".into());
            Box::pin(async { Ok(()) })
        }
    }

    #[derive(Clone, Default)]
    struct RecordingExporter(Arc<Mutex<Vec<SpanData>>>);

    impl fmt::Debug for RecordingExporter {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.debug_struct("RecordingExporter").finish()
        }
    }

    impl SpanExporter for RecordingExporter {
        async fn export(&self, batch: Vec<SpanData>) -> OTelSdkResult {
            self.0.lock().unwrap().extend(batch);
            Ok(())
        }
    }

    async fn capture_spans(
        future: impl Future<Output = Result<i32, String>>,
    ) -> (Result<i32, String>, Vec<SpanData>) {
        let exporter = RecordingExporter::default();
        let provider = SdkTracerProvider::builder()
            .with_simple_exporter(exporter.clone())
            .build();
        let tracer = provider.tracer("diesel-messaging-test");
        let subscriber = tracing_subscriber::registry()
            .with(tracing_opentelemetry::OpenTelemetryLayer::new(tracer));
        let dispatch = tracing::Dispatch::new(subscriber);
        let _guard = tracing::dispatcher::set_default(&dispatch);
        let result = future.await;
        provider.force_flush().unwrap();
        let spans = exporter.0.lock().unwrap().clone();
        (result, spans)
    }

    fn assert_error_spans(spans: &[SpanData], count: usize) {
        assert_eq!(spans.len(), count);
        for span in spans {
            assert!(matches!(span.status, Status::Error { .. }));
            assert!(
                span.events
                    .events
                    .iter()
                    .any(|event| event.name == "exception")
            );
        }
    }

    #[test]
    fn slow_session_setup_allows_each_broker_round_trip() {
        assert_eq!(
            session_setup_timeout(Duration::from_secs(10)),
            Duration::from_secs(80)
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn direct_publish_batches_one_confirmation_after_all_messages() {
        let session = FakeSession::direct(
            vec![FakeStep::Ready(Ok(())); 3],
            FakeStep::Ready(Ok(PublishConfirmation::Ack)),
        );

        assert_eq!(
            publish_direct_session(&session, 3, "direct", Duration::from_secs(1)).await,
            Ok(3)
        );
        assert_eq!(
            session.calls(),
            [
                "publish:direct-0",
                "publish:direct-1",
                "publish:direct-2",
                "group_confirm",
                "confirm:direct-0",
                "confirm:direct-1",
                "confirm:direct-2",
                "close",
            ]
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn slow_publish_confirms_each_message_before_the_next() {
        let session = FakeSession::slow(vec![
            FakeStep::Ready(Ok(PublishConfirmation::Ack)),
            FakeStep::Ready(Ok(PublishConfirmation::Ack)),
            FakeStep::Ready(Ok(PublishConfirmation::Ack)),
        ]);

        assert_eq!(
            publish_slow_session(&session, 3, "slow", Duration::from_secs(1)).await,
            Ok(3)
        );
        assert_eq!(
            session.calls(),
            [
                "publish:slow-0",
                "confirm:slow-0",
                "publish:slow-1",
                "confirm:slow-1",
                "publish:slow-2",
                "confirm:slow-2",
                "close",
            ]
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn direct_failures_mark_all_live_spans_and_close() {
        let cases = [
            (
                "wait error",
                vec![FakeStep::Ready(Ok(())); 2],
                FakeStep::Ready(Err("wait failed".into())),
            ),
            (
                "returned",
                vec![FakeStep::Ready(Ok(())); 2],
                FakeStep::Ready(Ok(PublishConfirmation::Returned)),
            ),
            (
                "nack",
                vec![FakeStep::Ready(Ok(())); 2],
                FakeStep::Ready(Ok(PublishConfirmation::Nack)),
            ),
            (
                "not requested",
                vec![FakeStep::Ready(Ok(())); 2],
                FakeStep::Ready(Ok(PublishConfirmation::NotRequested)),
            ),
        ];

        for (name, publishes, grouped) in cases {
            let session = FakeSession::direct(publishes, grouped);
            let (result, spans) = capture_spans(publish_direct_session(
                &session,
                2,
                "direct",
                Duration::from_secs(1),
            ))
            .await;
            assert!(result.is_err(), "{name}");
            assert_error_spans(&spans, 2);
            assert_eq!(session.calls().last().map(String::as_str), Some("close"));
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn direct_per_message_confirmation_failures_are_rejected() {
        let cases = [
            FakeStep::Ready(Err("confirmation failed".into())),
            FakeStep::Ready(Ok(PublishConfirmation::Returned)),
            FakeStep::Ready(Ok(PublishConfirmation::Nack)),
            FakeStep::Ready(Ok(PublishConfirmation::NotRequested)),
            FakeStep::Pending,
        ];

        for confirmation in cases {
            let session = FakeSession::direct_with_confirms(
                vec![FakeStep::Ready(Ok(()))],
                vec![confirmation],
                FakeStep::Ready(Ok(PublishConfirmation::Ack)),
            );
            let (result, spans) = capture_spans(publish_direct_session(
                &session,
                1,
                "direct",
                Duration::from_millis(1),
            ))
            .await;
            assert!(result.is_err());
            assert_error_spans(&spans, 1);
            assert_eq!(session.calls().last().map(String::as_str), Some("close"));
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn publish_error_and_timeout_mark_spans_and_close() {
        let cases = [
            FakeStep::Ready(Err("basic_publish failed".into())),
            FakeStep::Pending,
        ];

        for step in cases {
            let session =
                FakeSession::direct(vec![step], FakeStep::Ready(Ok(PublishConfirmation::Ack)));
            let (result, spans) = capture_spans(publish_direct_session(
                &session,
                1,
                "direct",
                Duration::from_millis(1),
            ))
            .await;
            assert!(result.is_err());
            assert_error_spans(&spans, 1);
            assert_eq!(session.calls().last().map(String::as_str), Some("close"));
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn slow_confirmation_failures_mark_the_span_and_close() {
        let cases = [
            FakeStep::Ready(Err("confirm failed".into())),
            FakeStep::Ready(Ok(PublishConfirmation::Returned)),
            FakeStep::Ready(Ok(PublishConfirmation::Nack)),
            FakeStep::Ready(Ok(PublishConfirmation::NotRequested)),
        ];

        for step in cases {
            let session = FakeSession::slow(vec![step]);
            let (result, spans) = capture_spans(publish_slow_session(
                &session,
                1,
                "slow",
                Duration::from_secs(1),
            ))
            .await;
            assert!(result.is_err());
            assert_error_spans(&spans, 1);
            assert_eq!(session.calls().last().map(String::as_str), Some("close"));
        }
    }

    #[tokio::test]
    async fn messaging_invalid_contract() {
        let calls = Arc::new(AtomicUsize::new(0));
        let publisher = Arc::new(RecordingPublisher {
            calls: calls.clone(),
        });
        let app = messaging_router(publisher);
        let invalid = [
            "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
        ];
        let malformed = [
            "/api/fault/n-plus-one-messaging?messages[]=8&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8items&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs[]=600&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600ms&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats[]=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=3times&broker=rabbitmq",
        ];

        for path in invalid.into_iter().chain(malformed) {
            let response = app
                .clone()
                .oneshot(Request::post(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), 400, "{path}");
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let marker = "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0";
        assert!(
            Command::new("printf")
                .args(["%s\\n", marker])
                .status()
                .unwrap()
                .success()
        );
    }
}
