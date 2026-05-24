package com.perfsim.helidonsesvc.web;

import io.helidon.webserver.http.HttpRules;
import io.helidon.webserver.http.HttpService;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import jakarta.json.Json;
import jakarta.json.JsonArray;
import jakarta.json.JsonArrayBuilder;
import jakarta.json.JsonObject;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import javax.sql.DataSource;

/**
 * Business endpoints reachable at /api/external/mock, /api/dispatch/{channel}
 * and /api/payments/history. Callbacks for the HTTP-side faults. Pure
 * Helidon SE — no CDI, plain functional routing handlers wired in {@link
 * com.perfsim.helidonsesvc.Main}.
 */
public final class BusinessRoutes implements HttpService {

    private static final Set<String> CHANNELS =
            Set.of("email", "sms", "push", "webhook", "slack", "teams");

    private final DataSource dataSource;

    public BusinessRoutes(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public void routing(HttpRules rules) {
        rules.get("/external/mock", this::mock);
        rules.get("/dispatch/{channel}", this::dispatch);
        rules.get("/payments/history", this::paymentsHistory);
    }

    private void mock(ServerRequest req, ServerResponse res) {
        long delayMs = req.query().first("delayMs").asLong().orElse(0L);
        int seq = req.query().first("seq").asInt().orElse(0);
        int op = req.query().first("op").asInt().orElse(0);
        sleepQuietly(delayMs);
        JsonObject body = Json.createObjectBuilder()
                .add("ok", true)
                .add("seq", seq)
                .add("op", op)
                .add("delayMs", delayMs)
                .build();
        res.send(body);
    }

    private void dispatch(ServerRequest req, ServerResponse res) {
        String channel = req.path().pathParameters().first("channel").orElse("");
        if (!CHANNELS.contains(channel)) {
            res.status(404).send("unknown channel: " + channel);
            return;
        }
        long delayMs = req.query().first("delayMs").asLong().orElse(0L);
        sleepQuietly(delayMs);
        JsonObject body = Json.createObjectBuilder()
                .add("channel", channel)
                .add("dispatched", true)
                .add("delayMs", delayMs)
                .build();
        res.send(body);
    }

    // Matches helidon-mp-svc / quarkus-svc / mutiny-svc which all
    // return List<Object[]> via JAX-RS, serialising to a JSON array
    // of positional arrays [id, order_id, customer_id, amount_cents,
    // status]. Returning array-of-objects here would silently diverge
    // the multistack contract for any cross-stack consumer.
    private void paymentsHistory(ServerRequest req, ServerResponse res) {
        long customerId = req.query().first("customerId").asLong().orElse(1L);
        int limit = req.query().first("limit").asInt().orElse(10);
        int safeLimit = Math.clamp(limit, 1, 100);
        List<JsonArray> rows = new ArrayList<>();
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(
                     "SELECT id, order_id, customer_id, amount_cents, status "
                             + "FROM helidon_se.payments WHERE customer_id = ? "
                             + "ORDER BY id LIMIT ?")) {
            ps.setLong(1, customerId);
            ps.setInt(2, safeLimit);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    rows.add(Json.createArrayBuilder()
                            .add(rs.getLong("id"))
                            .add(rs.getLong("order_id"))
                            .add(rs.getLong("customer_id"))
                            .add(rs.getLong("amount_cents"))
                            .add(rs.getString("status"))
                            .build());
                }
            }
        } catch (Exception e) {
            // Do not echo e.getMessage() — Postgres errors include the
            // role name and auth state, which would leak through to
            // the k6 logs and perf-sentinel artefacts.
            res.status(500).send("payments query failed");
            return;
        }
        JsonArrayBuilder arr = Json.createArrayBuilder();
        rows.forEach(arr::add);
        res.send(arr.build());
    }

    private static void sleepQuietly(long ms) {
        if (ms > 0) {
            try {
                Thread.sleep(ms);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
