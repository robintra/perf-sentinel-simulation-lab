package com.perfsim.quarkussvc.web;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

// Self-loop REST client. The HTTP-side faults (n-plus-one-http,
// redundant-http, slow-http, fanout, chatty, serialized) call back
// into this service's own business endpoints, so the multistack
// contract holds even when no other lab service is deployed.
//
// `configKey = "self"` binds the base URL to the
// `quarkus.rest-client.self.url` property in application.properties.
// quarkus-opentelemetry auto-instruments these calls so each outbound
// HTTP span lands at the OTel Collector tagged service=quarkus-svc.
@RegisterRestClient(configKey = "self")
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
