# laravel-svc

Laravel 13 + Eloquent multistack member (PHP 8.5, native OpenTelemetry). Port **8095**,
Postgres schema/role `laravel`/`laravel_user`. Exercises perf-sentinel's PHP framework-aware
`suggested_fix`: the app-wide `io.opentelemetry.contrib.php.laravel` scope rides every finding,
so all anti-patterns map to `suggested_fix.framework = php_laravel_eloquent`.

## Runtime

PHP built-in server with worker concurrency (`PHP_CLI_SERVER_WORKERS`, default 20), a single
container, no fpm/nginx. **The workers matter**: the HTTP fault endpoints call back into the
service (`SELF_BASE_URL`), and a single-worker server deadlocks on those reentrant
self-calls. OTel auto-instrumentation (`opentelemetry-auto-laravel` +
`opentelemetry-auto-pdo`) is enabled via `OTEL_PHP_AUTOLOAD_ENABLED=true`. OTel config is
passed as **real env vars** (the SDK autoloader reads `getenv()` before Laravel loads
`.env`).

## Endpoints

Implements the full [multistack contract](../../docs/MULTISTACK.md): 10
`POST /api/fault/<pattern>` endpoints + `/api/external/mock`, `/api/dispatch/{channel}`,
`/api/payments/history`, and `/health/live` `/health/ready`. SQL faults go through Eloquent.
HTTP faults emit their own CLIENT spans (carrying `url.full`) via `curl` / `curl_multi`.

## Build & deploy

```
make seed-laravel-svc          # docker build -> k3d import -> helm install
./scripts/run-multistack-scenario.sh laravel
```

`n-plus-one-sql` defaults to `items=20` (≥ 3 × `n_plus_one_threshold`) so the daemon's strict
sanitizer-aware classifier reclassifies the sanitized Eloquent group to `n_plus_one_sql`.
