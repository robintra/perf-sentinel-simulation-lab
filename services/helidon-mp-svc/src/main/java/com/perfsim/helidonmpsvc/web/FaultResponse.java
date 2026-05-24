package com.perfsim.helidonmpsvc.web;

import java.time.Instant;
import java.util.Map;

public record FaultResponse(
        String antiPattern,
        String service,
        long durationMs,
        Map<String, Object> details,
        Instant timestamp) {

    public static FaultResponse of(String antiPattern, String service, long durationMs, Map<String, Object> details) {
        return new FaultResponse(antiPattern, service, durationMs, details, Instant.now());
    }
}
