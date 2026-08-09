<?php

declare(strict_types=1);

namespace App\Support;

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use PhpAmqpLib\Channel\AMQPChannel;
use PhpAmqpLib\Connection\AMQPStreamConnection;
use PhpAmqpLib\Message\AMQPMessage;
use PhpAmqpLib\Wire\AMQPTable;
use RuntimeException;
use Throwable;

class Messaging
{
    private const DESTINATION = 'perfsim.laravel-svc';
    private const ROUTING_KEY = 'laravel-svc';
    private const DIRECT_TIMEOUT_SECONDS = 5.0;

    public function publishSequentially(int $messages): array
    {
        [$username, $password] = $this->credentials();
        $confirmed = $this->withChannel(false, self::DIRECT_TIMEOUT_SECONDS, $username, $password,
            function (AMQPChannel $channel, int &$acks) use ($messages): void {
                for ($index = 0; $index < $messages; $index++) {
                    $this->producerSpan(function () use ($channel, $index): void {
                        $this->publish($channel, "laravel-message-{$index}");
                    });
                }
                $channel->wait_for_pending_acks_returns(self::DIRECT_TIMEOUT_SECONDS);
            },
        );

        if ($confirmed !== $messages) {
            throw new RuntimeException("RabbitMQ confirmed {$confirmed} of {$messages} publications");
        }

        return ['published' => $messages, 'confirmed' => $confirmed];
    }

    public function publishSlowly(int $delayMs, int $repeats): array
    {
        [$username, $password] = $this->credentials();
        $this->updateLatency($delayMs);
        $operationTimeout = $delayMs / 1000 + self::DIRECT_TIMEOUT_SECONDS;
        $connectionTimeout = 2 * $operationTimeout + 1;

        $confirmed = $this->withChannel(true, $connectionTimeout, $username, $password,
            function (AMQPChannel $channel, int &$acks) use ($delayMs, $repeats, $operationTimeout): void {
                for ($index = 0; $index < $repeats; $index++) {
                    $before = $acks;
                    $this->producerSpan(function () use ($channel, $delayMs, $index, $operationTimeout): void {
                        $this->publish($channel, "slow-laravel-message-{$delayMs}-{$index}");
                        $channel->wait_for_pending_acks_returns($operationTimeout);
                    });
                    if ($acks !== $before + 1) {
                        throw new RuntimeException('RabbitMQ did not confirm exactly one slow publication');
                    }
                }
            },
        );

        if ($confirmed !== $repeats) {
            throw new RuntimeException("RabbitMQ confirmed {$confirmed} of {$repeats} publications");
        }

        return ['published' => $repeats, 'confirmed' => $confirmed, 'delay_ms' => $delayMs];
    }

    private function withChannel(
        bool $slow,
        float $timeout,
        string $username,
        string $password,
        callable $operation,
    ): int {
        $host = getenv($slow ? 'RABBITMQ_SLOW_HOST' : 'RABBITMQ_HOST')
            ?: ($slow ? 'toxiproxy.messaging.svc.cluster.local' : 'rabbitmq.messaging.svc.cluster.local');
        $port = (int) (getenv($slow ? 'RABBITMQ_SLOW_PORT' : 'RABBITMQ_PORT')
            ?: ($slow ? '25672' : '5672'));

        $connection = new AMQPStreamConnection(
            $host,
            $port,
            $username,
            $password,
            '/',
            false,
            'AMQPLAIN',
            null,
            'en_US',
            $timeout,
            $timeout,
            null,
            false,
            0,
            $timeout,
        );
        $channel = $connection->channel();
        $acks = 0;

        try {
            $channel->confirm_select();
            $channel->set_ack_handler(function () use (&$acks): void {
                $acks++;
            });
            $channel->set_nack_handler(function (): never {
                throw new RuntimeException('RabbitMQ negatively acknowledged a publication');
            });
            $channel->set_return_listener(function (int $code, string $text): never {
                throw new RuntimeException("RabbitMQ returned publication {$code}: {$text}");
            });
            $channel->exchange_declare(self::DESTINATION, 'direct', false, true, false);
            $channel->queue_declare(
                self::DESTINATION,
                false,
                true,
                false,
                false,
                false,
                new AMQPTable(['x-message-ttl' => 60_000]),
            );
            $channel->queue_bind(self::DESTINATION, self::DESTINATION, self::ROUTING_KEY);
            $operation($channel, $acks);
        } finally {
            try {
                $channel->close();
            } finally {
                $connection->close();
            }
        }

        return $acks;
    }

    private function publish(AMQPChannel $channel, string $payload): void
    {
        $channel->basic_publish(
            new AMQPMessage($payload, [
                'content_type' => 'text/plain',
                'delivery_mode' => AMQPMessage::DELIVERY_MODE_PERSISTENT,
            ]),
            self::DESTINATION,
            self::ROUTING_KEY,
            true,
        );
    }

    private function producerSpan(callable $operation): void
    {
        $span = Globals::tracerProvider()->getTracer('laravel-svc-messaging')
            ->spanBuilder(self::DESTINATION.' send')
            ->setSpanKind(SpanKind::KIND_PRODUCER)
            ->setAttribute('messaging.system', 'rabbitmq')
            ->setAttribute('messaging.destination.name', self::DESTINATION)
            ->setAttribute('messaging.operation.type', 'send')
            ->startSpan();
        $scope = $span->activate();

        try {
            $operation();
        } catch (Throwable $error) {
            $span->recordException($error);
            $span->setStatus(StatusCode::STATUS_ERROR, $error->getMessage());
            throw $error;
        } finally {
            $scope->detach();
            $span->end();
        }
    }

    private function credentials(): array
    {
        $username = getenv('RABBITMQ_USERNAME');
        $password = getenv('RABBITMQ_PASSWORD');
        if (!is_string($username) || $username === '' || !is_string($password) || $password === '') {
            throw new RuntimeException('RABBITMQ_USERNAME and RABBITMQ_PASSWORD are required');
        }
        return [$username, $password];
    }

    private function updateLatency(int $delayMs): void
    {
        $api = rtrim(
            getenv('TOXIPROXY_API') ?: 'http://toxiproxy.messaging.svc.cluster.local:8474',
            '/',
        );
        $update = "{$api}/proxies/rabbitmq-slow/toxics/latency_downstream";
        $status = $this->postJson($update, ['attributes' => ['latency' => $delayMs, 'jitter' => 0]]);
        if ($status === 404) {
            $status = $this->postJson("{$api}/proxies/rabbitmq-slow/toxics", [
                'name' => 'latency_downstream',
                'type' => 'latency',
                'stream' => 'downstream',
                'attributes' => ['latency' => $delayMs, 'jitter' => 0],
            ]);
            if ($status === 409) {
                $status = $this->postJson($update, ['attributes' => ['latency' => $delayMs, 'jitter' => 0]]);
            }
        }
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Toxiproxy update failed with HTTP {$status}");
        }
    }

    private function postJson(string $url, array $body): int
    {
        $json = json_encode($body, JSON_THROW_ON_ERROR);
        $context = stream_context_create(['http' => [
            'method' => 'POST',
            'header' => "Content-Type: application/json\r\nContent-Length: ".strlen($json)."\r\n",
            'content' => $json,
            'timeout' => self::DIRECT_TIMEOUT_SECONDS,
            'ignore_errors' => true,
        ]]);
        $result = @file_get_contents($url, false, $context);
        $statusLine = $http_response_header[0] ?? '';
        if (!preg_match('/^HTTP\/\S+\s+(\d{3})/', $statusLine, $match)) {
            throw new RuntimeException("Toxiproxy request failed: {$url}");
        }
        if ($result === false && (int) $match[1] < 400) {
            throw new RuntimeException("Toxiproxy response read failed: {$url}");
        }
        return (int) $match[1];
    }
}
