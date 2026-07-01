#!/bin/sh
# symfony-svc entrypoint: prepare the writable var/ dir the read-only rootfs needs
# (var/ is symlinked to /tmp, an empty emptyDir at start), run the idempotent
# schema bootstrap, warm the prod container cache, then start the built-in server
# with worker concurrency (PHP_CLI_SERVER_WORKERS) for the curl_multi faults.
set -e

mkdir -p /tmp/var/cache /tmp/var/log

# Idempotent schema + seed (pg advisory-locked). Blocks until Postgres answers.
php /app/docker/bootstrap-schema.php

# Compile the prod container up-front so the first request isn't slow / racy.
php /app/bin/console cache:warmup --env=prod --no-debug >/dev/null 2>&1 || true

cd /app
exec php -S 0.0.0.0:"${HTTP_PORT:-8096}" server.php
