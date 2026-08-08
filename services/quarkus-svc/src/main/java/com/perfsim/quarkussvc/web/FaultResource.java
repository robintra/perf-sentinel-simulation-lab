package com.perfsim.quarkussvc.web;

import com.perfsim.quarkussvc.messaging.MessagingFaultService;
import io.agroal.api.AgroalDataSource;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.DefaultValue;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.function.Supplier;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import org.eclipse.microprofile.context.ManagedExecutor;
import org.eclipse.microprofile.rest.client.inject.RestClient;

/**
 * 12 fault endpoints, one per perf-sentinel anti-pattern. Contract is
 * defined in docs/MULTISTACK.md. Each endpoint reproduces the same
 * wire-format behaviour as the Java baseline order-service /
 * payment-service / notification-service but using Quarkus / Panache /
 * Agroal / MicroProfile RestClient idioms so the OTel auto-instrumentation
 * sees the exact span shapes the detectors expect.
 */
@Path("/api/fault")
@Produces(MediaType.APPLICATION_JSON)
public class FaultResource {

    private static final String SERVICE = "quarkus-svc";

    @Inject
    EntityManager em;

    @Inject
    @RestClient
    SelfClient self;

    @Inject
    AgroalDataSource dataSource;

    @Inject
    ManagedExecutor executor;

    @Inject
    MessagingFaultService messagingFaultService;

    // === fault response helper =================================================

    private FaultResponse runFault(
            String antiPattern, Map<String, Object> input, Supplier<Map<String, Object>> body) {
        long start = System.nanoTime();
        Map<String, Object> details = new HashMap<>(input);
        Map<String, Object> bodyDetails = body.get();
        if (bodyDetails != null) {
            details.putAll(bodyDetails);
        }
        long durationMs = (System.nanoTime() - start) / 1_000_000L;
        return FaultResponse.of(antiPattern, SERVICE, durationMs, details);
    }

    // === SQL anti-patterns =====================================================

    @POST
    @Path("/n-plus-one-sql")
    @Transactional
    public FaultResponse nPlusOneSql(@QueryParam("items") @DefaultValue("15") int items) {
        return runFault("n_plus_one_sql", Map.of("items", items), () -> {
            int total = 0;
            // Lab-only: literal interpolated into the SQL string so the OTel JDBC
            // instrumentation captures N distinct templates. Prepared statements
            // would all share the same `?` template and the detector would
            // classify as redundant_sql. Never reproduce this pattern in any
            // code path that handles untrusted input.
            for (int orderId = 1; orderId <= items; orderId++) {
                Object count = em.createNativeQuery(
                                "SELECT count(*) FROM quarkus.order_items WHERE order_id = " + orderId)
                        .getSingleResult();
                if (count instanceof Number n) {
                    total += n.intValue();
                }
            }
            return Map.of("orders_touched", items, "items_total", total);
        });
    }

    @POST
    @Path("/redundant-sql")
    @Transactional
    public FaultResponse redundantSql(@QueryParam("repeats") @DefaultValue("10") int repeats) {
        return runFault("redundant_sql", Map.of("repeats", repeats), () -> {
            int total = 0;
            // Same SQL string, same literal parameters, repeated. The sanitizer
            // sees a single template repeated `repeats` times.
            for (int i = 0; i < repeats; i++) {
                Object count = em.createNativeQuery(
                                "SELECT count(*) FROM quarkus.payments WHERE customer_id = 1")
                        .getSingleResult();
                if (count instanceof Number n) {
                    total += n.intValue();
                }
            }
            return Map.of("queries_made", repeats, "rows_seen", total);
        });
    }

    @POST
    @Path("/slow-sql")
    @Transactional
    public FaultResponse slowSql(
            @QueryParam("delayMs") @DefaultValue("600") long delayMs,
            @QueryParam("repeats") @DefaultValue("6") int repeats) {
        return runFault(
                "slow_sql",
                Map.of("delayMs", delayMs, "repeats", repeats),
                () -> {
                    double seconds = delayMs / 1000.0;
                    int executed = 0;
                    // Distinct templates per iteration so this is not collapsed into
                    // redundant_sql. The OFFSET literal changes each loop.
                    for (int i = 0; i < repeats; i++) {
                        em.createNativeQuery(
                                        "SELECT pg_sleep(" + seconds + "), * FROM quarkus.orders "
                                                + "ORDER BY id OFFSET " + i + " LIMIT 1")
                                .getResultList();
                        executed++;
                    }
                    return Map.of("queries_executed", executed, "delay_ms", delayMs);
                });
    }

    @POST
    @Path("/pool-saturation")
    public FaultResponse poolSaturation(
            @QueryParam("concurrency") @DefaultValue("20") int concurrency) {
        return runFault("pool_saturation", Map.of("concurrency", concurrency), () -> {
            Context requestContext = Context.current();
            // Agroal pool cap = 10 (quarkus.datasource.jdbc.max-size in
            // application.properties). Launching concurrency=20 tasks each
            // holding a connection ~400 ms forces 10 tasks to queue behind
            // 10 in-flight ones, lighting up the saturation detector.
            List<CompletableFuture<Integer>> futures = new ArrayList<>();
            for (int i = 0; i < concurrency; i++) {
                futures.add(executor.supplyAsync(() -> {
                    try (Scope ignored = requestContext.makeCurrent();
                            Connection conn = dataSource.getConnection();
                         PreparedStatement ps = conn.prepareStatement("SELECT pg_sleep(0.4)")) {
                        ps.execute();
                        return 1;
                    } catch (Exception e) {
                        throw new RuntimeException("pool-saturation worker failed", e);
                    }
                }));
            }
            int completed = futures.stream()
                    .mapToInt(CompletableFuture::join)
                    .sum();
            return Map.of("tasks_launched", concurrency, "tasks_completed", completed);
        });
    }

    // === HTTP anti-patterns ====================================================

    @POST
    @Path("/n-plus-one-http")
    public FaultResponse nPlusOneHttp(
            @QueryParam("recipients") @DefaultValue("10") int recipients) {
        return runFault("n_plus_one_http", Map.of("recipients", recipients), () -> {
            int ok = 0;
            // Distinct query templates per call (seq=i) so the detector sees
            // N spans with different attributes, not one repeated.
            for (int i = 0; i < recipients; i++) {
                try (Response r = self.mock(0L, i, 0)) {
                    if (r.getStatus() == 200) ok++;
                }
            }
            return Map.of("calls_made", recipients, "calls_ok", ok);
        });
    }

    @POST
    @Path("/redundant-http")
    public FaultResponse redundantHttp(@QueryParam("repeats") @DefaultValue("10") int repeats) {
        return runFault("redundant_http", Map.of("repeats", repeats), () -> {
            int ok = 0;
            // Same URL same params each iteration.
            for (int i = 0; i < repeats; i++) {
                try (Response r = self.paymentsHistory(1L, 10)) {
                    if (r.getStatus() == 200) ok++;
                }
            }
            return Map.of("calls_made", repeats, "calls_ok", ok);
        });
    }

    @POST
    @Path("/slow-http")
    public FaultResponse slowHttp(
            @QueryParam("delayMs") @DefaultValue("600") long delayMs,
            @QueryParam("repeats") @DefaultValue("6") int repeats) {
        return runFault(
                "slow_http",
                Map.of("delayMs", delayMs, "repeats", repeats),
                () -> {
                    int ok = 0;
                    for (int i = 0; i < repeats; i++) {
                        try (Response r = self.mock(delayMs, i, 0)) {
                            if (r.getStatus() == 200) ok++;
                        }
                    }
                    return Map.of("calls_made", repeats, "calls_ok", ok, "delay_ms", delayMs);
                });
    }

    @POST
    @Path("/fanout")
    public FaultResponse fanout(@QueryParam("width") @DefaultValue("40") int width) {
        return runFault("excessive_fanout", Map.of("width", width), () -> {
            // Parallel outbound calls via ManagedExecutor (context propagation
            // ensures the OTel trace context flows into each worker).
            List<CompletableFuture<Integer>> futures = new ArrayList<>();
            for (int i = 0; i < width; i++) {
                final int seq = i;
                futures.add(executor.supplyAsync(() -> {
                    try (Response r = self.mock(10L, seq, 0)) {
                        return r.getStatus() == 200 ? 1 : 0;
                    }
                }));
            }
            int ok = futures.stream().mapToInt(CompletableFuture::join).sum();
            return Map.of("children_launched", width, "children_ok", ok);
        });
    }

    @POST
    @Path("/chatty")
    public FaultResponse chatty(@QueryParam("calls") @DefaultValue("30") int calls) {
        return runFault("chatty_service", Map.of("calls", calls), () -> {
            int ok = 0;
            // Varying templates (seq=i, op=i%7) avoid the n-plus-one classification
            // while still emitting `calls` outbound spans, which is the chatty
            // signature.
            for (int i = 0; i < calls; i++) {
                try (Response r = self.mock(5L, i, i % 7)) {
                    if (r.getStatus() == 200) ok++;
                }
            }
            return Map.of("calls_made", calls, "calls_ok", ok);
        });
    }

    @POST
    @Path("/serialized")
    public FaultResponse serialized(@QueryParam("steps") @DefaultValue("6") int steps) {
        return runFault("serialized_calls", Map.of("steps", steps), () -> {
            String[] channels = {"email", "sms", "push", "webhook", "slack", "teams"};
            long startNs = System.nanoTime();
            int ok = 0;
            for (int i = 0; i < Math.min(steps, channels.length); i++) {
                try (Response r = self.dispatch(channels[i], 80L)) {
                    if (r.getStatus() == 200) ok++;
                }
            }
            long wallClockMs = (System.nanoTime() - startNs) / 1_000_000L;
            return Map.of("steps_ok", ok, "wall_clock_ms", wallClockMs);
        });
    }

    @POST
    @Path("/n-plus-one-messaging")
    public Response nPlusOneMessaging(
            @QueryParam("messages") @DefaultValue("8") int messages,
            @QueryParam("broker") @DefaultValue("rabbitmq") String broker) {
        if (!"rabbitmq".equals(broker) || messages < 5 || messages > 100) {
            return Response.status(Response.Status.BAD_REQUEST).build();
        }
        return Response.ok(runFault(
                        "n_plus_one_messaging",
                        Map.of("messages", messages, "broker", broker),
                        () -> messagingFaultService.publishSequentially(messages)))
                .build();
    }

    @POST
    @Path("/slow-messaging")
    public Response slowMessaging(
            @QueryParam("delayMs") @DefaultValue("600") long delayMs,
            @QueryParam("repeats") @DefaultValue("3") int repeats,
            @QueryParam("broker") @DefaultValue("rabbitmq") String broker) {
        if (!"rabbitmq".equals(broker) || delayMs < 501 || delayMs > 5_000 || repeats < 3 || repeats > 20) {
            return Response.status(Response.Status.BAD_REQUEST).build();
        }
        return Response.ok(runFault(
                        "slow_messaging",
                        Map.of("delayMs", delayMs, "repeats", repeats, "broker", broker),
                        () -> messagingFaultService.publishSlowly(delayMs, repeats)))
                .build();
    }
}
