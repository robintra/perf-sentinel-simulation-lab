<?php
// Router for the PHP built-in server (php -S ... server.php run from /app).
// Serves real files under public/ directly; everything else goes through the
// Symfony front controller so the auto-symfony instrumentation wraps the kernel.
$uri = urldecode(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
if ($uri !== '/' && is_file(__DIR__.'/public'.$uri)) {
    return false;
}
$_SERVER['SCRIPT_FILENAME'] = __DIR__.'/public/index.php';
$_SERVER['SCRIPT_NAME'] = '/index.php';
require __DIR__.'/public/index.php';
