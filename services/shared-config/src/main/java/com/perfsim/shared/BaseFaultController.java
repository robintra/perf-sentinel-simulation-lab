package com.perfsim.shared;

import java.util.Map;
import java.util.concurrent.Callable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

public abstract class BaseFaultController {

    protected final Logger log = LoggerFactory.getLogger(getClass());

    protected abstract String serviceName();

    protected ResponseEntity<FaultResponse> runFault(
            String antiPattern, Map<String, Object> params, Callable<Map<String, Object>> action) {
        long start = System.nanoTime();
        log.info("fault start anti_pattern={} params={}", antiPattern, params);
        try {
            Map<String, Object> details = action.call();
            long durationMs = (System.nanoTime() - start) / 1_000_000L;
            log.info(
                    "fault end anti_pattern={} duration_ms={} details={}",
                    antiPattern,
                    durationMs,
                    details);
            return ResponseEntity.ok(
                    FaultResponse.success(antiPattern, serviceName(), durationMs, details));
        } catch (Exception e) {
            long durationMs = (System.nanoTime() - start) / 1_000_000L;
            log.error("fault failed anti_pattern={} duration_ms={}", antiPattern, durationMs, e);
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body(
                            FaultResponse.success(
                                    antiPattern,
                                    serviceName(),
                                    durationMs,
                                    Map.of("error", e.getClass().getSimpleName(), "message", e.getMessage())));
        }
    }
}
