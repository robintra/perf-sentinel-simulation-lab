<?php

declare(strict_types=1);

use App\Controller\FaultController;
use App\Kernel;
use App\Support\Messaging;
use Symfony\Component\HttpFoundation\Request;

putenv('APP_ENV=prod');
putenv('APP_DEBUG=0');
putenv('APP_SECRET=test');
putenv('OTEL_SDK_DISABLED=true');
putenv('DB_HOST=127.0.0.1');
putenv('DB_PORT=1');
putenv('DB_NAME=test');
putenv('DB_USER=test');
putenv('DB_PASSWORD=test');
@mkdir('/tmp/var/cache', 0777, true);
@mkdir('/tmp/var/log', 0777, true);

require __DIR__.'/../vendor/autoload.php';

$kernel = new Kernel('prod', false);
$kernel->boot();
$container = $kernel->getContainer();

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

$entityManager = $container->get('doctrine')->getManager();
$controller = new FaultController($entityManager, $spy);
$controller->setContainer($container);
$container->set(FaultController::class, $controller);

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

$kernel->shutdown();

if ($accepted !== 7 || $spy->publishSequentiallyCalls !== 0 || $spy->publishSlowlyCalls !== 0) {
    fwrite(
        STDERR,
        "contract mismatch: accepted={$accepted} sequential={$spy->publishSequentiallyCalls} slow={$spy->publishSlowlyCalls}\n",
    );
    exit(1);
}

echo "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0\n";
