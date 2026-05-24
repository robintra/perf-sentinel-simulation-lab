package com.perfsim.mutinysvc.web;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.pgclient.PgPool;
import io.vertx.mutiny.sqlclient.Row;
import jakarta.inject.Inject;
import jakarta.ws.rs.DefaultValue;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.HashMap;
import java.util.Map;
import org.eclipse.microprofile.rest.client.inject.RestClient;

/**
 * Reactive (Mutiny) version of the 10 fault endpoints. Same contract
 * as quarkus-svc's FaultResource (see docs/MULTISTACK.md), but every
 * method returns Uni&lt;FaultResponse&gt; and threading goes through the
 * Vert.x event loop. PgPool drives the SQL anti-patterns; the reactive
 * RestClient drives the HTTP ones. Parallel patterns use
 * `transformToUniAndMerge`; sequential ones use `transformToUniAndConcatenate`.
 */
@Path("/api/fault")
@Produces(MediaType.APPLICATION_JSON)
public class FaultResource {

    private static final String SERVICE = "mutiny-svc";
    private static final String[] CHANNELS = {"email", "sms", "push", "webhook", "slack", "teams"};

    @Inject
    PgPool pgPool;

    @Inject
    @RestClient
    SelfClient self;

    private Uni<FaultResponse> runFault(
            String antiPattern, Map<String, Object> input, Uni<Map<String, Object>> body) {
        long start = System.nanoTime();
        return body.onItem().transform(extra -> {
            Map<String, Object> details = new HashMap<>(input);
            if (extra != null) {
                details.putAll(extra);
            }
            long durationMs = (System.nanoTime() - start) / 1_000_000L;
            return FaultResponse.of(antiPattern, SERVICE, durationMs, details);
        });
    }

    // === SQL anti-patterns =====================================================

    @POST
    @Path("/n-plus-one-sql")
    public Uni<FaultResponse> nPlusOneSql(@QueryParam("items") @DefaultValue("15") int items) {
        // Realistic Vert.x reactive PG client n+1 shape: N literal-
        // interpolated SQL statements driven by the application code
        // directly, no ORM in the loop. This is exactly what a
        // reactive-stack microservice writes when it forgets to batch.
        //
        // Important known gap: with OTel sanitizers ENABLED (the
        // prod default), perf-sentinel's strict classifier needs an
        // ORM scope marker (org.hibernate.*) to reclassify a
        // sanitized batch as n_plus_one_sql. The Vert.x reactive PG
        // client emits no such marker, so the detector lands on
        // redundant_sql instead. That is a real perf-sentinel
        // detection gap on bare-driver stacks (Vert.x SQL client,
        // pgx, asyncpg, ...) that the lab is here to surface — we
        // do NOT paper over it from the service side via SQL
        // comments or sanitizer toggles, see
        // memory/project_perf_sentinel_followup.md.
        return runFault("n_plus_one_sql", Map.of("items", items),
                Multi.createFrom().range(1, items + 1)
                        .onItem().transformToUniAndConcatenate(orderId ->
                                pgPool.query(
                                        "SELECT count(*) FROM mutiny.order_items WHERE order_id = " + orderId)
                                        .execute()
                                        .onItem().transform(rs -> {
                                            Row r = rs.iterator().next();
                                            return ((Number) r.getValue(0)).intValue();
                                        }))
                        .collect().asList()
                        .onItem().transform(counts -> Map.of(
                                "orders_touched", items,
                                "items_total", counts.stream().mapToInt(Integer::intValue).sum())));
    }

    @POST
    @Path("/redundant-sql")
    public Uni<FaultResponse> redundantSql(@QueryParam("repeats") @DefaultValue("10") int repeats) {
        return runFault("redundant_sql", Map.of("repeats", repeats),
                Multi.createFrom().range(0, repeats)
                        .onItem().transformToUniAndConcatenate(i ->
                                pgPool.query(
                                        "SELECT count(*) FROM mutiny.payments WHERE customer_id = 1")
                                        .execute()
                                        .onItem().transform(rs -> {
                                            Row r = rs.iterator().next();
                                            return ((Number) r.getValue(0)).intValue();
                                        }))
                        .collect().asList()
                        .onItem().transform(counts -> Map.of(
                                "queries_made", repeats,
                                "rows_seen", counts.stream().mapToInt(Integer::intValue).sum())));
    }

    @POST
    @Path("/slow-sql")
    public Uni<FaultResponse> slowSql(
            @QueryParam("delayMs") @DefaultValue("600") long delayMs,
            @QueryParam("repeats") @DefaultValue("6") int repeats) {
        double seconds = delayMs / 1000.0;
        return runFault("slow_sql", Map.of("delayMs", delayMs, "repeats", repeats),
                Multi.createFrom().range(0, repeats)
                        .onItem().transformToUniAndConcatenate(i ->
                                pgPool.query(
                                        "SELECT pg_sleep(" + seconds + "), * FROM mutiny.orders "
                                                + "ORDER BY id OFFSET " + i + " LIMIT 1")
                                        .execute()
                                        .onItem().transform(rs -> 1))
                        .collect().asList()
                        .onItem().transform(results -> Map.of(
                                "queries_executed", results.size(),
                                "delay_ms", delayMs)));
    }

    @POST
    @Path("/pool-saturation")
    public Uni<FaultResponse> poolSaturation(
            @QueryParam("concurrency") @DefaultValue("20") int concurrency) {
        // The reactive PG pool is capped at 10 in application.properties.
        // Launching concurrency=20 parallel queries via transformToUniAndMerge
        // forces 10 queries to queue behind 10 in-flight ones — the
        // saturation signal the detector picks up.
        return runFault("pool_saturation", Map.of("concurrency", concurrency),
                Multi.createFrom().range(0, concurrency)
                        .onItem().transformToUniAndMerge(i ->
                                pgPool.query("SELECT pg_sleep(0.4)")
                                        .execute()
                                        .onItem().transform(rs -> 1))
                        .collect().asList()
                        .onItem().transform(results -> Map.of(
                                "tasks_launched", concurrency,
                                "tasks_completed", results.size())));
    }

    // === HTTP anti-patterns ====================================================

    private static int statusOk(Response r) {
        int s = r.getStatus();
        r.close();
        return s == 200 ? 1 : 0;
    }

    @POST
    @Path("/n-plus-one-http")
    public Uni<FaultResponse> nPlusOneHttp(
            @QueryParam("recipients") @DefaultValue("10") int recipients) {
        return runFault("n_plus_one_http", Map.of("recipients", recipients),
                Multi.createFrom().range(0, recipients)
                        .onItem().transformToUniAndConcatenate(i ->
                                self.mock(0L, i, 0).onItem().transform(FaultResource::statusOk))
                        .collect().asList()
                        .onItem().transform(oks -> Map.of(
                                "calls_made", recipients,
                                "calls_ok", oks.stream().mapToInt(Integer::intValue).sum())));
    }

    @POST
    @Path("/redundant-http")
    public Uni<FaultResponse> redundantHttp(@QueryParam("repeats") @DefaultValue("10") int repeats) {
        return runFault("redundant_http", Map.of("repeats", repeats),
                Multi.createFrom().range(0, repeats)
                        .onItem().transformToUniAndConcatenate(i ->
                                self.paymentsHistory(1L, 10).onItem().transform(FaultResource::statusOk))
                        .collect().asList()
                        .onItem().transform(oks -> Map.of(
                                "calls_made", repeats,
                                "calls_ok", oks.stream().mapToInt(Integer::intValue).sum())));
    }

    @POST
    @Path("/slow-http")
    public Uni<FaultResponse> slowHttp(
            @QueryParam("delayMs") @DefaultValue("600") long delayMs,
            @QueryParam("repeats") @DefaultValue("6") int repeats) {
        return runFault("slow_http", Map.of("delayMs", delayMs, "repeats", repeats),
                Multi.createFrom().range(0, repeats)
                        .onItem().transformToUniAndConcatenate(i ->
                                self.mock(delayMs, i, 0).onItem().transform(FaultResource::statusOk))
                        .collect().asList()
                        .onItem().transform(oks -> Map.of(
                                "calls_made", repeats,
                                "calls_ok", oks.stream().mapToInt(Integer::intValue).sum(),
                                "delay_ms", delayMs)));
    }

    @POST
    @Path("/fanout")
    public Uni<FaultResponse> fanout(@QueryParam("width") @DefaultValue("40") int width) {
        return runFault("excessive_fanout", Map.of("width", width),
                Multi.createFrom().range(0, width)
                        .onItem().transformToUniAndMerge(i ->
                                self.mock(10L, i, 0).onItem().transform(FaultResource::statusOk))
                        .collect().asList()
                        .onItem().transform(oks -> Map.of(
                                "children_launched", width,
                                "children_ok", oks.stream().mapToInt(Integer::intValue).sum())));
    }

    @POST
    @Path("/chatty")
    public Uni<FaultResponse> chatty(@QueryParam("calls") @DefaultValue("30") int calls) {
        return runFault("chatty_service", Map.of("calls", calls),
                Multi.createFrom().range(0, calls)
                        .onItem().transformToUniAndConcatenate(i ->
                                self.mock(5L, i, i % 7).onItem().transform(FaultResource::statusOk))
                        .collect().asList()
                        .onItem().transform(oks -> Map.of(
                                "calls_made", calls,
                                "calls_ok", oks.stream().mapToInt(Integer::intValue).sum())));
    }

    @POST
    @Path("/serialized")
    public Uni<FaultResponse> serialized(@QueryParam("steps") @DefaultValue("6") int steps) {
        long start = System.nanoTime();
        int boundedSteps = Math.min(steps, CHANNELS.length);
        return runFault("serialized_calls", Map.of("steps", steps),
                Multi.createFrom().range(0, boundedSteps)
                        .onItem().transformToUniAndConcatenate(i ->
                                self.dispatch(CHANNELS[i], 80L).onItem().transform(FaultResource::statusOk))
                        .collect().asList()
                        .onItem().transform(oks -> {
                            long wallClockMs = (System.nanoTime() - start) / 1_000_000L;
                            return Map.of(
                                    "steps_ok", oks.stream().mapToInt(Integer::intValue).sum(),
                                    "wall_clock_ms", wallClockMs);
                        }));
    }

}
