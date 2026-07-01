<?php

use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Support\Facades\Route;

// The fault/health/business routes are registered in the `then` closure with an
// EMPTY middleware group: no CSRF (POST would 419), no throttle (k6 would 429),
// no sessions. Requests still flow through Illuminate\Foundation\Http\Kernel,
// which opentelemetry-auto-laravel hooks, so the SERVER span always carries the
// io.opentelemetry.contrib.php.laravel scope the daemon keys on.
return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
        then: function () {
            Route::group([], base_path('routes/faults.php'));
        },
    )
    ->withMiddleware(function (Middleware $middleware) {
        //
    })
    ->withExceptions(function (Exceptions $exceptions) {
        //
    })->create();
