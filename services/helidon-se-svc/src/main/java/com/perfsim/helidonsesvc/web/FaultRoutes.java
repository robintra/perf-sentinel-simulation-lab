package com.perfsim.helidonsesvc.web;

import io.helidon.webserver.http.HttpRules;
import io.helidon.webserver.http.HttpService;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import jakarta.json.JsonObject;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.function.Supplier;
import javax.sql.DataSource;

/**
 * 10 fault endpoints for the perf-sentinel multistack contract. Pure
 * Helidon SE: HttpService registered programmatically in {@link
 * com.perfsim.helidonsesvc.Main}, raw JDBC for SQL anti-patterns
 * (HikariCP-backed DataSource, no ORM), {@link java.net.http.HttpClient}
 * (JDK stdlib) for HTTP anti-patterns.
 *
 * Two stack-specific traits worth noting:
 *
 * <ul>
 *   <li>No Hibernate. The OTel JDBC sanitizer collapses literal SQL into a
 *   {@code ?} template and, without an ORM scope marker, perf-sentinel's
 *   strict classifier lands on {@code redundant_sql} instead of
 *   {@code n_plus_one_sql}. That is the third data point on Gap #20
 *   (after mutiny-svc); see the upstream report.</li>
 *
 *   <li>The outbound HTTP client is {@link java.net.http.HttpClient} from
 *   the JDK, not Helidon's own WebClient. Reason: the OpenTelemetry Java
 *   agent v2.27 ships {@code io.opentelemetry.helidon-4.3} for the
 *   server side only — there is no Helidon WebClient instrumentation in
 *   either the agent or {@code opentelemetry-java-contrib}. Helidon's
 *   own {@code helidon-webclient-tracing} module sits behind
 *   {@code helidon-tracing-providers-opentelemetry}, which calls
 *   {@code GlobalOpenTelemetry.set(...)} — a no-op when the agent is
 *   active (verified in the pod logs of helidon-se-svc v2). The
 *   realistic prod fallback is the JDK stdlib client, which is covered
 *   by the agent's {@code io.opentelemetry.java-http-client}
 *   instrumentation. WebServer stays Helidon SE; only the client moves
 *   to stdlib. The Helidon WebClient gap is documented for upstream.</li>
 * </ul>
 */
public final class FaultRoutes implements HttpService {

    private static final String SERVICE = "helidon-se-svc";
    private static final String[] CHANNELS = {"email", "sms", "push", "webhook", "slack", "teams"};

    private final DataSource dataSource;
    private final HttpClient httpClient;
    private final String selfBaseUrl;
    // Cached pool for fanout / pool-saturation concurrency. Threads
    // are marked daemon and given a recognisable name so a SIGTERM
    // does not need to wait for them to drain (otherwise the JVM
    // refuses to exit until the 60 s keep-alive lapses, which
    // collides with the deployment's terminationGracePeriodSeconds
    // and ends in a SIGKILL).
    private final Executor executor = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r);
        t.setDaemon(true);
        t.setName("helidon-se-fault-" + t.threadId());
        return t;
    });

    public FaultRoutes(DataSource dataSource, HttpClient httpClient, String selfBaseUrl) {
        this.dataSource = dataSource;
        this.httpClient = httpClient;
        this.selfBaseUrl = selfBaseUrl.endsWith("/")
                ? selfBaseUrl.substring(0, selfBaseUrl.length() - 1)
                : selfBaseUrl;
    }

    @Override
    public void routing(HttpRules rules) {
        rules.post("/n-plus-one-sql", this::nPlusOneSql);
        rules.post("/n-plus-one-http", this::nPlusOneHttp);
        rules.post("/redundant-sql", this::redundantSql);
        rules.post("/redundant-http", this::redundantHttp);
        rules.post("/slow-sql", this::slowSql);
        rules.post("/slow-http", this::slowHttp);
        rules.post("/fanout", this::fanout);
        rules.post("/chatty", this::chatty);
        rules.post("/serialized", this::serialized);
        rules.post("/pool-saturation", this::poolSaturation);
    }

    // === plumbing =============================================================

    private JsonObject runFault(
            String antiPattern, Map<String, Object> input, Supplier<Map<String, Object>> body) {
        long start = System.nanoTime();
        Map<String, Object> details = new HashMap<>(input);
        Map<String, Object> bodyDetails = body.get();
        if (bodyDetails != null) {
            details.putAll(bodyDetails);
        }
        long durationMs = (System.nanoTime() - start) / 1_000_000L;
        return FaultResponse.build(antiPattern, SERVICE, durationMs, details);
    }

    private int statusOk(int status) {
        return status == 200 ? 1 : 0;
    }

    // Per-request timeout cap. The HttpClient builder's connectTimeout
    // only covers the TCP handshake; without an HttpRequest-level
    // timeout, a self-loop call that hangs after connect (Hikari pool
    // starved upstream, k6 saturating Loom, …) blocks the WebServer
    // handler thread indefinitely. 15s is loose enough for slow-http
    // (delayMs=600 × 6 = 3.6 s) and slow-sql piggybacks but tight
    // enough to surface a stuck call as a 5xx within the k6 iteration
    // window instead of pinning the pod.
    private static final Duration SELF_CALL_TIMEOUT = Duration.ofSeconds(15);

    private int sendGet(String path) {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(selfBaseUrl + path))
                .timeout(SELF_CALL_TIMEOUT)
                .GET()
                .build();
        try {
            HttpResponse<Void> r = httpClient.send(request, HttpResponse.BodyHandlers.discarding());
            return statusOk(r.statusCode());
        } catch (Exception e) {
            throw new RuntimeException("self HTTP call failed: " + path, e);
        }
    }

    private int callMock(long delayMs, int seq, int op) {
        return sendGet("/api/external/mock?delayMs=" + delayMs + "&seq=" + seq + "&op=" + op);
    }

    private int callDispatch(String channel, long delayMs) {
        return sendGet("/api/dispatch/" + channel + "?delayMs=" + delayMs);
    }

    private int callPaymentsHistory(long customerId, int limit) {
        return sendGet("/api/payments/history?customerId=" + customerId + "&limit=" + limit);
    }

    // === SQL anti-patterns =====================================================

    private void nPlusOneSql(ServerRequest req, ServerResponse res) {
        int items = req.query().first("items").asInt().orElse(15);
        JsonObject body = runFault("n_plus_one_sql", Map.of("items", items), () -> {
            int total = 0;
            try (Connection conn = dataSource.getConnection();
                 Statement st = conn.createStatement()) {
                // Lab-only: literal interpolation. The OTel JDBC sanitizer
                // collapses these N statements to one template (`?`), so
                // the strict classifier reclassifies as redundant_sql
                // without an ORM marker. Gap #20 again.
                for (int orderId = 1; orderId <= items; orderId++) {
                    try (ResultSet rs = st.executeQuery(
                            "SELECT count(*) FROM helidon_se.order_items WHERE order_id = " + orderId)) {
                        if (rs.next()) {
                            total += rs.getInt(1);
                        }
                    }
                }
            } catch (Exception e) {
                throw new RuntimeException("n-plus-one-sql failed", e);
            }
            return Map.of("orders_touched", items, "items_total", total);
        });
        res.send(body);
    }

    private void redundantSql(ServerRequest req, ServerResponse res) {
        int repeats = req.query().first("repeats").asInt().orElse(10);
        JsonObject body = runFault("redundant_sql", Map.of("repeats", repeats), () -> {
            int total = 0;
            try (Connection conn = dataSource.getConnection();
                 Statement st = conn.createStatement()) {
                for (int i = 0; i < repeats; i++) {
                    try (ResultSet rs = st.executeQuery(
                            "SELECT count(*) FROM helidon_se.payments WHERE customer_id = 1")) {
                        if (rs.next()) {
                            total += rs.getInt(1);
                        }
                    }
                }
            } catch (Exception e) {
                throw new RuntimeException("redundant-sql failed", e);
            }
            return Map.of("queries_made", repeats, "rows_seen", total);
        });
        res.send(body);
    }

    private void slowSql(ServerRequest req, ServerResponse res) {
        long delayMs = req.query().first("delayMs").asLong().orElse(600L);
        int repeats = req.query().first("repeats").asInt().orElse(6);
        JsonObject body = runFault(
                "slow_sql",
                Map.of("delayMs", delayMs, "repeats", repeats),
                () -> {
                    double seconds = delayMs / 1000.0;
                    int executed = 0;
                    try (Connection conn = dataSource.getConnection();
                         Statement st = conn.createStatement()) {
                        for (int i = 0; i < repeats; i++) {
                            try (ResultSet rs = st.executeQuery(
                                    "SELECT pg_sleep(" + seconds + "), * FROM helidon_se.orders "
                                            + "ORDER BY id OFFSET " + i + " LIMIT 1")) {
                                while (rs.next()) { /* drain */ }
                            }
                            executed++;
                        }
                    } catch (Exception e) {
                        throw new RuntimeException("slow-sql failed", e);
                    }
                    return Map.of("queries_executed", executed, "delay_ms", delayMs);
                });
        res.send(body);
    }

    private void poolSaturation(ServerRequest req, ServerResponse res) {
        int concurrency = req.query().first("concurrency").asInt().orElse(20);
        JsonObject body = runFault("pool_saturation", Map.of("concurrency", concurrency), () -> {
            List<CompletableFuture<Integer>> futures = new ArrayList<>();
            for (int i = 0; i < concurrency; i++) {
                futures.add(CompletableFuture.supplyAsync(() -> {
                    try (Connection conn = dataSource.getConnection();
                         PreparedStatement ps = conn.prepareStatement("SELECT pg_sleep(0.4)")) {
                        ps.execute();
                        return 1;
                    } catch (Exception e) {
                        throw new RuntimeException("pool-saturation worker failed", e);
                    }
                }, executor));
            }
            int completed = futures.stream().mapToInt(CompletableFuture::join).sum();
            return Map.of("tasks_launched", concurrency, "tasks_completed", completed);
        });
        res.send(body);
    }

    // === HTTP anti-patterns ====================================================

    private void nPlusOneHttp(ServerRequest req, ServerResponse res) {
        int recipients = req.query().first("recipients").asInt().orElse(10);
        JsonObject body = runFault("n_plus_one_http", Map.of("recipients", recipients), () -> {
            int ok = 0;
            for (int i = 0; i < recipients; i++) {
                ok += callMock(0L, i, 0);
            }
            return Map.of("calls_made", recipients, "calls_ok", ok);
        });
        res.send(body);
    }

    private void redundantHttp(ServerRequest req, ServerResponse res) {
        int repeats = req.query().first("repeats").asInt().orElse(10);
        JsonObject body = runFault("redundant_http", Map.of("repeats", repeats), () -> {
            int ok = 0;
            for (int i = 0; i < repeats; i++) {
                ok += callPaymentsHistory(1L, 10);
            }
            return Map.of("calls_made", repeats, "calls_ok", ok);
        });
        res.send(body);
    }

    private void slowHttp(ServerRequest req, ServerResponse res) {
        long delayMs = req.query().first("delayMs").asLong().orElse(600L);
        int repeats = req.query().first("repeats").asInt().orElse(6);
        JsonObject body = runFault(
                "slow_http",
                Map.of("delayMs", delayMs, "repeats", repeats),
                () -> {
                    int ok = 0;
                    for (int i = 0; i < repeats; i++) {
                        ok += callMock(delayMs, i, 0);
                    }
                    return Map.of("calls_made", repeats, "calls_ok", ok, "delay_ms", delayMs);
                });
        res.send(body);
    }

    private void fanout(ServerRequest req, ServerResponse res) {
        int width = req.query().first("width").asInt().orElse(40);
        JsonObject body = runFault("excessive_fanout", Map.of("width", width), () -> {
            List<CompletableFuture<Integer>> futures = new ArrayList<>();
            for (int i = 0; i < width; i++) {
                final int seq = i;
                futures.add(CompletableFuture.supplyAsync(
                        () -> callMock(10L, seq, 0),
                        executor));
            }
            int ok = futures.stream().mapToInt(CompletableFuture::join).sum();
            return Map.of("children_launched", width, "children_ok", ok);
        });
        res.send(body);
    }

    private void chatty(ServerRequest req, ServerResponse res) {
        int calls = req.query().first("calls").asInt().orElse(30);
        JsonObject body = runFault("chatty_service", Map.of("calls", calls), () -> {
            int ok = 0;
            for (int i = 0; i < calls; i++) {
                ok += callMock(5L, i, i % 7);
            }
            return Map.of("calls_made", calls, "calls_ok", ok);
        });
        res.send(body);
    }

    private void serialized(ServerRequest req, ServerResponse res) {
        int steps = req.query().first("steps").asInt().orElse(6);
        JsonObject body = runFault("serialized_calls", Map.of("steps", steps), () -> {
            long startNs = System.nanoTime();
            int ok = 0;
            for (int i = 0; i < Math.min(steps, CHANNELS.length); i++) {
                ok += callDispatch(CHANNELS[i], 80L);
            }
            long wallClockMs = (System.nanoTime() - startNs) / 1_000_000L;
            return Map.of("steps_ok", ok, "wall_clock_ms", wallClockMs);
        });
        res.send(body);
    }
}
