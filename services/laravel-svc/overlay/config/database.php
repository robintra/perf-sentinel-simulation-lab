<?php

// Minimal Postgres-only database config. Reads the DB_* env names the helm
// deployment injects (same names as rails-svc). search_path pins the per-service
// `laravel` schema so unqualified Eloquent table names resolve there.
return [
    'default' => env('DB_CONNECTION', 'pgsql'),

    'connections' => [
        'pgsql' => [
            'driver' => 'pgsql',
            'host' => env('DB_HOST', 'localhost'),
            'port' => env('DB_PORT', '5432'),
            'database' => env('DB_NAME', 'lab'),
            'username' => env('DB_USER', 'laravel_user'),
            'password' => env('DB_PASSWORD', 'lab_laravel'),
            'charset' => 'utf8',
            'prefix' => '',
            'prefix_indexes' => true,
            'search_path' => env('DB_SCHEMA', 'laravel').',public',
            'sslmode' => 'prefer',
        ],
    ],

    'migrations' => [
        'table' => 'migrations',
        'update_date_on_publish' => true,
    ],

    'redis' => [],
];
