package com.perfsim.notification.web;

import com.perfsim.shared.BaseFaultController;
import com.perfsim.shared.FaultResponse;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
@RequestMapping("/api/fault")
public class FaultController extends BaseFaultController {

    private final RestClient selfClient;

    public FaultController(RestClient selfClient) {
        this.selfClient = selfClient;
    }

    @Override
    protected String serviceName() {
        return "notification-service";
    }

    @PostMapping("/n-plus-one-http")
    public ResponseEntity<FaultResponse> nPlusOneHttp(
            @RequestParam(defaultValue = "10") int recipients) {
        return runFault(
                "n_plus_one_http",
                Map.of("recipients", recipients),
                () -> {
                    int ok = 0;
                    for (int i = 0; i < recipients; i++) {
                        // Same call template repeated. Detector picks this up as
                        // n_plus_one_http when count >= n_plus_one_min_occurrences.
                        selfClient
                                .get()
                                .uri("/api/external/mock?delayMs=0&recipient={r}", i)
                                .retrieve()
                                .toBodilessEntity();
                        ok++;
                    }
                    return Map.of("calls_made", recipients, "calls_ok", ok);
                });
    }

    @PostMapping("/fanout")
    public ResponseEntity<FaultResponse> fanout(
            @RequestParam(defaultValue = "40") int width) {
        return runFault(
                "excessive_fanout",
                Map.of("width", width),
                () -> {
                    ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor();
                    try {
                        List<CompletableFuture<Boolean>> futures = new java.util.ArrayList<>();
                        for (int i = 0; i < width; i++) {
                            futures.add(CompletableFuture.supplyAsync(
                                    () -> {
                                        selfClient
                                                .get()
                                                .uri("/api/external/mock?delayMs=10")
                                                .retrieve()
                                                .toBodilessEntity();
                                        return Boolean.TRUE;
                                    },
                                    pool));
                        }
                        long ok = futures.stream()
                                .map(CompletableFuture::join)
                                .filter(Boolean::booleanValue)
                                .count();
                        return Map.of("children_launched", width, "children_ok", ok);
                    } finally {
                        pool.shutdown();
                    }
                });
    }

    @PostMapping("/chatty")
    public ResponseEntity<FaultResponse> chatty(
            @RequestParam(defaultValue = "30") int calls) {
        return runFault(
                "chatty_service",
                Map.of("calls", calls),
                () -> {
                    int ok = 0;
                    for (int i = 0; i < calls; i++) {
                        // Vary the URL slightly so each call template is distinct,
                        // which shifts the detector from n_plus_one_http to
                        // chatty_service (high outbound count, varied templates).
                        selfClient
                                .get()
                                .uri("/api/external/mock?delayMs=5&seq={s}&op={o}", i, i % 7)
                                .retrieve()
                                .toBodilessEntity();
                        ok++;
                    }
                    return Map.of("calls_made", calls, "calls_ok", ok);
                });
    }

    private static final String[] CHANNELS = {
        "/api/dispatch/email",
        "/api/dispatch/sms",
        "/api/dispatch/push",
        "/api/dispatch/webhook",
        "/api/dispatch/slack",
        "/api/dispatch/teams"
    };

    @PostMapping("/serialized")
    public ResponseEntity<FaultResponse> serialized(
            @RequestParam(defaultValue = "6") int steps) {
        return runFault(
                "serialized_calls",
                Map.of("steps", steps),
                () -> {
                    long start = System.nanoTime();
                    int ok = 0;
                    // Each step hits a distinct route template (email, sms, push,
                    // webhook, slack, teams). With distinct templates the detector
                    // does not classify the loop as n_plus_one_http and falls back
                    // to serialized_calls, which is what the lab is showcasing.
                    for (int i = 0; i < steps; i++) {
                        String path = CHANNELS[i % CHANNELS.length];
                        selfClient
                                .get()
                                .uri(path + "?delayMs=80")
                                .retrieve()
                                .toBodilessEntity();
                        ok++;
                    }
                    long durMs = (System.nanoTime() - start) / 1_000_000L;
                    return Map.of("steps", steps, "steps_ok", ok, "wall_clock_ms", durMs);
                });
    }
}
