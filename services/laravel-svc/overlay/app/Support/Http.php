<?php

namespace App\Support;

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\Context\Context;

// Outbound HTTP helper that emits its OWN CLIENT span carrying `url.full` — the
// attribute perf-sentinel's ingest needs to classify a span as HTTP I/O. We do
// NOT rely on guzzle/curl auto-instrumentation (its CLIENT spans omit url.full).
// W3C traceparent is injected so the self-call's child SERVER span (and its SQL
// span, for pool-saturation) parent onto our CLIENT span and stay in one trace —
// which is what carries the app-wide io.opentelemetry.contrib.php.laravel scope
// down the leaf-to-root chain the daemon walks.
class Http
{
    private static function tracer()
    {
        return Globals::tracerProvider()->getTracer('laravel-svc-http');
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

    // One sequential GET under one CLIENT span. Returns 1 on HTTP 200, else 0.
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

    // Concurrent GETs via curl_multi, each under its own CLIENT span, so the
    // spans overlap in wall-clock (excessive_fanout) and the fanned-out child
    // requests hit distinct built-in-server workers (pool_saturation). Returns
    // the count of HTTP 200 responses.
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
