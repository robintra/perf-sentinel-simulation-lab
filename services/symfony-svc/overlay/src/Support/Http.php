<?php

namespace App\Support;

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\Context\Context;

// Outbound HTTP helper that emits its OWN CLIENT span carrying `url.full`. The
// tracer scope (symfony-svc-http) is NOT a framework scope, and the enclosing
// SERVER span carries only io.opentelemetry.contrib.php.symfony, which is not a
// vendor rule, so HTTP findings fall through the leaf-to-root chain to php_generic
// (there is no php.doctrine scope on a pure HTTP path). W3C traceparent is injected
// so the self-call children stay in one trace.
class Http
{
    private static function tracer()
    {
        return Globals::tracerProvider()->getTracer('symfony-svc-http');
    }

    private static function headersFor(Context $ctx): array
    {
        $carrier = [];
        Globals::propagator()->inject($carrier, null, $ctx);
        $headers = [];
        foreach ($carrier as $k => $v) {
            $headers[] = "{$k}: {$v}";
        }
        return $headers;
    }

    public static function get(string $url): int
    {
        $span = self::tracer()->spanBuilder('HTTP GET')
            ->setSpanKind(SpanKind::KIND_CLIENT)
            ->setAttribute('url.full', $url)
            ->setAttribute('http.request.method', 'GET')
            ->startSpan();
        $scope = $span->activate();
        try {
            $ch = curl_init($url);
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT => 20,
                CURLOPT_HTTPHEADER => self::headersFor(Context::getCurrent()),
            ]);
            curl_exec($ch);
            $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
            curl_close($ch);
            $span->setAttribute('http.response.status_code', $code);
            return $code === 200 ? 1 : 0;
        } finally {
            $span->end();
            $scope->detach();
        }
    }

    public static function getMany(array $urls): int
    {
        $mh = curl_multi_init();
        $handles = [];
        $spans = [];
        foreach ($urls as $url) {
            $span = self::tracer()->spanBuilder('HTTP GET')
                ->setSpanKind(SpanKind::KIND_CLIENT)
                ->setAttribute('url.full', $url)
                ->setAttribute('http.request.method', 'GET')
                ->startSpan();
            $ctx = $span->storeInContext(Context::getCurrent());
            $ch = curl_init($url);
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT => 30,
                CURLOPT_HTTPHEADER => self::headersFor($ctx),
            ]);
            curl_multi_add_handle($mh, $ch);
            $handles[] = $ch;
            $spans[] = $span;
        }

        do {
            $status = curl_multi_exec($mh, $running);
            if ($running && curl_multi_select($mh, 1.0) === -1) {
                // libcurl returns -1 when there is no fd to wait on; back off a
                // touch instead of busy-spinning the worker at 100% CPU (which
                // would also skew the lab's Scaphandre power findings).
                usleep(100);
            }
        } while ($running && $status === CURLM_OK);

        $ok = 0;
        foreach ($handles as $i => $ch) {
            $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
            $spans[$i]->setAttribute('http.response.status_code', $code);
            $spans[$i]->end();
            if ($code === 200) {
                $ok++;
            }
            curl_multi_remove_handle($mh, $ch);
            curl_close($ch);
        }
        curl_multi_close($mh);
        return $ok;
    }
}
