package com.perfsim.helidonmpsvc.web;

import com.perfsim.helidonmpsvc.messaging.MessagingPublisher;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
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
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.function.Supplier;
import javax.sql.DataSource;
import org.eclipse.microprofile.rest.client.inject.RestClient;

/**
 * 12 fault endpoints, one per perf-sentinel anti-pattern. Helidon MP
 * idiom: MicroProfile JAX-RS + CDI + JPA Hibernate. SQL anti-patterns
 * go through the JPA EntityManager (literal-interpolated native
 * queries; the OTel Java agent at runtime tags them with the
 * org.hibernate.* scope marker that perf-sentinel's strict classifier
 * reads). HTTP anti-patterns go through the MP REST Client.
 */
@Path("/api/fault")
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class FaultResource {

    private static final String SERVICE = "helidon-mp-svc";
    private static final String[] CHANNELS = {"email", "sms", "push", "webhook", "slack", "teams"};

    @PersistenceContext(unitName = "helidonMpPU")
    EntityManager em;

    private final SelfClient self;

    // Helidon HikariCP datasource, looked up via CDI. Used by
    // pool-saturation to grab N raw connections that bypass JPA.
    private final DataSource dataSource;

    private final MessagingPublisher messagingPublisher;

    @Inject
    public FaultResource(
            @RestClient SelfClient self,
            DataSource dataSource,
            MessagingPublisher messagingPublisher) {
        this.self = self;
        this.dataSource = dataSource;
        this.messagingPublisher = messagingPublisher;
    }

    FaultResource(MessagingPublisher messagingPublisher) {
        this(null, null, messagingPublisher);
    }

    private final Executor executor = Executors.newCachedThreadPool();

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
            for (int orderId = 1; orderId <= items; orderId++) {
                Object count = em.createNativeQuery(
                                "SELECT count(*) FROM helidon_mp.order_items WHERE order_id = " + orderId)
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
            for (int i = 0; i < repeats; i++) {
                Object count = em.createNativeQuery(
                                "SELECT count(*) FROM helidon_mp.payments WHERE customer_id = 1")
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
                    for (int i = 0; i < repeats; i++) {
                        em.createNativeQuery(
                                        "SELECT pg_sleep(" + seconds + "), * FROM helidon_mp.orders "
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
            // HikariCP pool capped at 10 in application.yaml. Launching
            // 20 concurrent connections each held ~400 ms forces 10 to
            // queue behind 10 in-flight.
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
    }

    // === HTTP anti-patterns ====================================================

    private static int statusOk(Response r) {
        int s = r.getStatus();
        r.close();
        return s == 200 ? 1 : 0;
    }

    @POST
    @Path("/n-plus-one-http")
    public FaultResponse nPlusOneHttp(
            @QueryParam("recipients") @DefaultValue("10") int recipients) {
        return runFault("n_plus_one_http", Map.of("recipients", recipients), () -> {
            int ok = 0;
            for (int i = 0; i < recipients; i++) {
                ok += statusOk(self.mock(0L, i, 0));
            }
            return Map.of("calls_made", recipients, "calls_ok", ok);
        });
    }

    @POST
    @Path("/redundant-http")
    public FaultResponse redundantHttp(@QueryParam("repeats") @DefaultValue("10") int repeats) {
        return runFault("redundant_http", Map.of("repeats", repeats), () -> {
            int ok = 0;
            for (int i = 0; i < repeats; i++) {
                ok += statusOk(self.paymentsHistory(1L, 10));
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
                        ok += statusOk(self.mock(delayMs, i, 0));
                    }
                    return Map.of("calls_made", repeats, "calls_ok", ok, "delay_ms", delayMs);
                });
    }

    @POST
    @Path("/fanout")
    public FaultResponse fanout(@QueryParam("width") @DefaultValue("40") int width) {
        return runFault("excessive_fanout", Map.of("width", width), () -> {
            List<CompletableFuture<Integer>> futures = new ArrayList<>();
            for (int i = 0; i < width; i++) {
                final int seq = i;
                futures.add(CompletableFuture.supplyAsync(
                        () -> statusOk(self.mock(10L, seq, 0)),
                        executor));
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
            for (int i = 0; i < calls; i++) {
                ok += statusOk(self.mock(5L, i, i % 7));
            }
            return Map.of("calls_made", calls, "calls_ok", ok);
        });
    }

    @POST
    @Path("/serialized")
    public FaultResponse serialized(@QueryParam("steps") @DefaultValue("6") int steps) {
        return runFault("serialized_calls", Map.of("steps", steps), () -> {
            long startNs = System.nanoTime();
            int ok = 0;
            for (int i = 0; i < Math.min(steps, CHANNELS.length); i++) {
                ok += statusOk(self.dispatch(CHANNELS[i], 80L));
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
                        () -> messagingPublisher.publishSequentially(messages)))
                .build();
    }

    @POST
    @Path("/slow-messaging")
    public Response slowMessaging(
            @QueryParam("delayMs") @DefaultValue("600") long delayMs,
            @QueryParam("repeats") @DefaultValue("3") int repeats,
            @QueryParam("broker") @DefaultValue("rabbitmq") String broker) {
        if (!"rabbitmq".equals(broker)
                || delayMs < 501
                || delayMs > 5_000
                || repeats < 3
                || repeats > 20) {
            return Response.status(Response.Status.BAD_REQUEST).build();
        }
        return Response.ok(runFault(
                        "slow_messaging",
                        Map.of("delayMs", delayMs, "repeats", repeats, "broker", broker),
                        () -> messagingPublisher.publishSlowly(delayMs, repeats)))
                .build();
    }
}
