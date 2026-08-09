<?php

declare(strict_types=1);

use App\Support\Messaging;
use Illuminate\Contracts\Http\Kernel;
use Illuminate\Http\Request;

putenv('OTEL_SDK_DISABLED=true');
foreach ([
    '/tmp/storage/app',
    '/tmp/storage/framework/cache/data',
    '/tmp/storage/framework/sessions',
    '/tmp/storage/framework/views',
    '/tmp/storage/logs',
    '/tmp/bootstrap-cache',
] as $directory) {
    if (!is_dir($directory) && !mkdir($directory, 0777, true) && !is_dir($directory)) {
        throw new RuntimeException("failed to create {$directory}");
    }
}

require __DIR__.'/../vendor/autoload.php';

$app = require __DIR__.'/../bootstrap/app.php';
$kernel = $app->make(Kernel::class);

$spy = new class extends Messaging {
    public int $publishSequentiallyCalls = 0;
    public int $publishSlowlyCalls = 0;

    public function publishSequentially(int $messages): array
    {
        $this->publishSequentiallyCalls++;
        throw new RuntimeException('invalid request reached RabbitMQ');
    }

    public function publishSlowly(int $delayMs, int $repeats): array
    {
        $this->publishSlowlyCalls++;
        throw new RuntimeException('invalid request reached RabbitMQ or Toxiproxy');
    }
};

$app->instance(Messaging::class, $spy);

$invalid = [
    '/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq',
    '/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq',
    '/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq',
    '/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq',
    '/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq',
    '/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq',
    '/api/fault/n-plus-one-messaging?messages=8&broker=unsupported',
];

$accepted = 0;
foreach ($invalid as $path) {
    $request = Request::create($path, 'POST', server: ['HTTP_ACCEPT' => 'application/json']);
    $response = $kernel->handle($request);
    $kernel->terminate($request, $response);
    if ($response->getStatusCode() !== 400) {
        fwrite(STDERR, "{$path}: expected HTTP 400, got {$response->getStatusCode()}\n");
        exit(1);
    }
    $accepted++;
}

if ($accepted !== 7 || $spy->publishSequentiallyCalls !== 0 || $spy->publishSlowlyCalls !== 0) {
    fwrite(
        STDERR,
        "contract mismatch: accepted={$accepted} sequential={$spy->publishSequentiallyCalls} slow={$spy->publishSlowlyCalls}\n",
    );
    exit(1);
}

echo "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0\n";
