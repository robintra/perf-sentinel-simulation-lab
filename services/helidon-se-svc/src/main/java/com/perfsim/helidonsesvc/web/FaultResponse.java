package com.perfsim.helidonsesvc.web;

import jakarta.json.Json;
import jakarta.json.JsonObject;
import jakarta.json.JsonObjectBuilder;
import java.time.Instant;
import java.util.Map;

/**
 * Helidon SE-friendly fault response. Built as a JSON-P {@link JsonObject}
 * so the WebServer's JSON-P media support can serialize it without any
 * reflective JSON binding library (Helidon SE stays minimal-dep).
 */
public final class FaultResponse {

    private FaultResponse() {}

    public static JsonObject build(
            String antiPattern, String service, long durationMs, Map<String, Object> details) {
        JsonObjectBuilder detailsObj = Json.createObjectBuilder();
        for (Map.Entry<String, Object> e : details.entrySet()) {
            Object v = e.getValue();
            if (v instanceof Number n) {
                detailsObj.add(e.getKey(), n.longValue());
            } else if (v instanceof Boolean b) {
                detailsObj.add(e.getKey(), b);
            } else if (v == null) {
                detailsObj.addNull(e.getKey());
            } else {
                detailsObj.add(e.getKey(), v.toString());
            }
        }
        return Json.createObjectBuilder()
                .add("antiPattern", antiPattern)
                .add("service", service)
                .add("durationMs", durationMs)
                .add("details", detailsObj)
                .add("timestamp", Instant.now().toString())
                .build();
    }
}
