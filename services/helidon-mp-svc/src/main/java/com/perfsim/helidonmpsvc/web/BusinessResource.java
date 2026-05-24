package com.perfsim.helidonmpsvc.web;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.DefaultValue;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Business endpoints called back by the HTTP-side fault endpoints in
 * the same service. Same surface as quarkus-svc / mutiny-svc per
 * docs/MULTISTACK.md.
 */
@Path("/api")
@Produces(MediaType.APPLICATION_JSON)
@ApplicationScoped
public class BusinessResource {

    private static final Set<String> CHANNELS =
            Set.of("email", "sms", "push", "webhook", "slack", "teams");

    @PersistenceContext(unitName = "helidonMpPU")
    EntityManager em;

    @GET
    @Path("/external/mock")
    public Map<String, Object> mock(
            @QueryParam("delayMs") @DefaultValue("0") long delayMs,
            @QueryParam("seq") @DefaultValue("0") int seq,
            @QueryParam("op") @DefaultValue("0") int op) {
        if (delayMs > 0) {
            try {
                Thread.sleep(delayMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return Map.of("ok", true, "seq", seq, "op", op, "delayMs", delayMs);
    }

    @GET
    @Path("/dispatch/{channel}")
    public Map<String, Object> dispatch(
            @PathParam("channel") String channel,
            @QueryParam("delayMs") @DefaultValue("0") long delayMs) {
        if (!CHANNELS.contains(channel)) {
            throw new NotFoundException("unknown channel: " + channel);
        }
        if (delayMs > 0) {
            try {
                Thread.sleep(delayMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return Map.of("channel", channel, "dispatched", true, "delayMs", delayMs);
    }

    @GET
    @Path("/payments/history")
    @Transactional
    public List<Object[]> paymentsHistory(
            @QueryParam("customerId") @DefaultValue("1") long customerId,
            @QueryParam("limit") @DefaultValue("10") int limit) {
        int safeLimit = Math.clamp(limit, 1, 100);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(
                        "SELECT id, order_id, customer_id, amount_cents, status "
                                + "FROM helidon_mp.payments WHERE customer_id = ?1 "
                                + "ORDER BY id LIMIT ?2")
                .setParameter(1, customerId)
                .setParameter(2, safeLimit)
                .getResultList();
        return rows;
    }
}
