# symfony-svc

Symfony 7 + Doctrine ORM multistack member (PHP 8.3, native OpenTelemetry). Port **8096**,
Postgres schema/role `symfony`/`symfony_user`. Exercises perf-sentinel's PHP framework-aware
`suggested_fix` — and specifically the **Laravel/Doctrine asymmetry**: the DB-specific
`io.opentelemetry.contrib.php.doctrine` scope rides only SQL findings, so
- **SQL** findings map to `suggested_fix.framework = php_doctrine` (recommendation mentions a DQL
  fetch-join: `->leftJoin(...)->addSelect(...)`),
- **non-SQL** findings see only the `io.opentelemetry.contrib.php.symfony` scope (not a framework
  rule) and fall through to `php_generic`.

## Runtime

PHP built-in server with worker concurrency (`PHP_CLI_SERVER_WORKERS`, default 20) — single
container, no fpm/nginx. Workers are required for the reentrant HTTP self-calls. OTel
auto-instrumentation (`opentelemetry-auto-symfony` + `opentelemetry-auto-doctrine` +
`opentelemetry-auto-pdo`) is enabled via `OTEL_PHP_AUTOLOAD_ENABLED=true`; OTel config is passed
as **real env vars** (the SDK autoloader reads `getenv()` before Symfony loads `.env`).

## Endpoints

Implements the full [multistack contract](../../docs/MULTISTACK.md): 10 `POST /api/fault/<pattern>`
endpoints + `/api/external/mock`, `/api/dispatch/{channel}`, `/api/payments/history`, and
`/health/live` `/health/ready`. SQL faults go through Doctrine (`Repository::findBy` /
`Connection::executeQuery`); HTTP faults emit their own CLIENT spans via `curl` / `curl_multi`.

## Build & deploy

```
make seed-symfony-svc          # docker build -> k3d import -> helm install
./scripts/run-multistack-scenario.sh symfony
```

`n-plus-one-sql` defaults to `items=20` so the daemon's strict sanitizer-aware classifier
reclassifies the sanitized Doctrine group to `n_plus_one_sql`.
