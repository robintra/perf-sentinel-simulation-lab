package com.perfsim.mutinysvc.web;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.pgclient.PgPool;
import jakarta.inject.Inject;
import jakarta.ws.rs.DefaultValue;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Business endpoints called back by the HTTP-side fault endpoints of
 * the same service. Reactive: every method returns Uni&lt;...&gt; so the
 * delay loops are non-blocking and the event loop is preserved.
 */
@Path("/api")
@Produces(MediaType.APPLICATION_JSON)
public class BusinessResource {

    private static final Set<String> CHANNELS =
            Set.of("email", "sms", "push", "webhook", "slack", "teams");

    @Inject
    PgPool pgPool;

    @GET
    @Path("/external/mock")
    public Uni<Map<String, Object>> mock(
            @QueryParam("delayMs") @DefaultValue("0") long delayMs,
            @QueryParam("seq") @DefaultValue("0") int seq,
            @QueryParam("op") @DefaultValue("0") int op) {
        Uni<Map<String, Object>> body = Uni.createFrom().item(() -> Map.of(
                "ok", true,
                "seq", seq,
                "op", op,
                "delayMs", delayMs));
        return delayMs > 0
                ? body.onItem().delayIt().by(Duration.ofMillis(delayMs))
                : body;
    }

    @GET
    @Path("/dispatch/{channel}")
    public Uni<Map<String, Object>> dispatch(
            @PathParam("channel") String channel,
            @QueryParam("delayMs") @DefaultValue("0") long delayMs) {
        if (!CHANNELS.contains(channel)) {
            throw new NotFoundException("unknown channel: " + channel);
        }
        Uni<Map<String, Object>> body = Uni.createFrom().item(() -> Map.of(
                "channel", channel,
                "dispatched", true,
                "delayMs", delayMs));
        return delayMs > 0
                ? body.onItem().delayIt().by(Duration.ofMillis(delayMs))
                : body;
    }

    @GET
    @Path("/payments/history")
    public Uni<List<Map<String, Object>>> paymentsHistory(
            @QueryParam("customerId") @DefaultValue("1") long customerId,
            @QueryParam("limit") @DefaultValue("10") int limit) {
        int safeLimit = Math.min(Math.max(limit, 1), 100);
        return pgPool.preparedQuery(
                        "SELECT id, order_id, customer_id, amount_cents, status "
                                + "FROM mutiny.payments WHERE customer_id = $1 "
                                + "ORDER BY id LIMIT $2")
                .execute(io.vertx.mutiny.sqlclient.Tuple.of(customerId, safeLimit))
                .onItem().transform(rs -> {
                    List<Map<String, Object>> rows = new ArrayList<>();
                    rs.forEach(row -> {
                        Map<String, Object> m = new HashMap<>();
                        m.put("id", row.getLong("id"));
                        m.put("order_id", row.getLong("order_id"));
                        m.put("customer_id", row.getLong("customer_id"));
                        m.put("amount_cents", row.getLong("amount_cents"));
                        m.put("status", row.getString("status"));
                        rows.add(m);
                    });
                    return rows;
                });
    }
}
