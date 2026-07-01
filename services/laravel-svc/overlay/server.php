<?php
// Router for the PHP built-in server (php -S ... server.php run from /app).
// Serves real files under public/ directly; everything else goes through the
// Laravel front controller so the auto-laravel instrumentation wraps the kernel.
$uri = urldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
if ($uri !== '/' && file_exists(__DIR__.'/public'.$uri)) {
    return false;
}
require_once __DIR__.'/public/index.php';
