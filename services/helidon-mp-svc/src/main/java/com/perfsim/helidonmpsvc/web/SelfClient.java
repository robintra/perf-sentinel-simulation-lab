package com.perfsim.helidonmpsvc.web;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/**
 * Self-loop REST client. The HTTP-side faults call back into this
 * service's own business endpoints, so the multistack contract holds
 * regardless of what other multistack services are deployed. The base
 * URL is configured via the MP convention key
 * `com.perfsim.helidonmpsvc.web.SelfClient/mp-rest/url` in
 * microprofile-config.properties.
 */
@RegisterRestClient
public interface SelfClient {

    @GET
    @Path("/api/external/mock")
    Response mock(
            @QueryParam("delayMs") long delayMs,
            @QueryParam("seq") int seq,
            @QueryParam("op") int op);

    @GET
    @Path("/api/dispatch/{channel}")
    Response dispatch(
            @PathParam("channel") String channel,
            @QueryParam("delayMs") long delayMs);

    @GET
    @Path("/api/payments/history")
    Response paymentsHistory(
            @QueryParam("customerId") long customerId,
            @QueryParam("limit") int limit);
}
