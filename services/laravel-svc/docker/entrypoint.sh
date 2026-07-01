#!/bin/sh
# laravel-svc entrypoint: prepare the writable dirs the read-only rootfs needs
# (storage/ + bootstrap/cache are symlinked to /tmp, an empty emptyDir at start),
# run the idempotent schema bootstrap, then start the built-in server with worker
# concurrency (PHP_CLI_SERVER_WORKERS) so curl_multi fan-out hits real workers.
set -e

mkdir -p /tmp/storage/app \
         /tmp/storage/framework/cache/data \
         /tmp/storage/framework/sessions \
         /tmp/storage/framework/views \
         /tmp/storage/logs \
         /tmp/bootstrap-cache

# Idempotent schema + seed (pg advisory-locked). Blocks until Postgres answers.
php /app/docker/bootstrap-schema.php

# Build the package manifest once up-front so concurrent workers never race to
# write bootstrap/cache/packages.php on the first request.
php /app/artisan package:discover --ansi >/dev/null 2>&1 || true

cd /app
exec php -S 0.0.0.0:"${HTTP_PORT:-8095}" server.php
