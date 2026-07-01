<?php

namespace App\Controller;

use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;

trait Common
{
    private const SERVICE = 'symfony-svc';
    private const CHANNELS = ['email', 'sms', 'push', 'webhook', 'slack', 'teams'];

    private function intParam(Request $r, string $key, int $default): int
    {
        // query->all()[$key] tolerates bracketed array params (?items[]=9);
        // query->get() would throw BadRequestException on them. A non-string
        // value falls through to the default, matching the Laravel port.
        $v = $r->query->all()[$key] ?? null;
        return is_string($v) && $v !== '' ? (int) $v : $default;
    }

    private function selfBase(): string
    {
        return getenv('SELF_BASE_URL')
            ?: 'http://localhost:'.(getenv('HTTP_PORT') ?: '8096');
    }

    private function envelope(string $antiPattern, float $startNs, array $details): JsonResponse
    {
        $durationMs = (int) ((hrtime(true) - $startNs) / 1_000_000);
        return new JsonResponse([
            'antiPattern' => $antiPattern,
            'service' => self::SERVICE,
            'durationMs' => $durationMs,
            'details' => $details,
            'timestamp' => (new \DateTimeImmutable('now', new \DateTimeZone('UTC')))
                ->format('Y-m-d\TH:i:s.v\Z'),
        ]);
    }
}
