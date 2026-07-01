<?php

namespace App\Http\Controllers\Concerns;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

trait Common
{
    protected const SERVICE = 'laravel-svc';
    protected const CHANNELS = ['email', 'sms', 'push', 'webhook', 'slack', 'teams'];

    // Coerce a query param to int, falling back to $default for anything that is
    // not a plain scalar string (bracketed params parse to arrays with no int).
    protected function intParam(Request $r, string $key, int $default): int
    {
        $v = $r->query($key);
        return is_string($v) && $v !== '' ? (int) $v : $default;
    }

    protected function selfBase(): string
    {
        return getenv('SELF_BASE_URL')
            ?: 'http://localhost:'.(getenv('HTTP_PORT') ?: '8095');
    }

    protected function envelope(string $antiPattern, float $startNs, array $details): JsonResponse
    {
        $durationMs = (int) ((hrtime(true) - $startNs) / 1_000_000);
        return response()->json([
            'antiPattern' => $antiPattern,
            'service' => self::SERVICE,
            'durationMs' => $durationMs,
            'details' => $details,
            'timestamp' => (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))
                ->format('Y-m-d\TH:i:s.v\Z'),
        ]);
    }
}
