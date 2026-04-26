package com.perfsim.shared;

import java.time.Instant;
import java.util.Map;

public record FaultResponse(
        String antiPattern,
        String service,
        long durationMs,
        Map<String, Object> details,
        Instant timestamp) {

    public static FaultResponse success(
            String antiPattern, String service, long durationMs, Map<String, Object> details) {
        return new FaultResponse(antiPattern, service, durationMs, details, Instant.now());
    }
}
