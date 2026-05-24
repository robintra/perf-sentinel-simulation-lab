package com.perfsim.mutinysvc.web;

import io.smallrye.mutiny.Uni;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

// Reactive self-loop REST client. Each method returns Uni<Response>
// so the HTTP-side faults can compose via Mutiny operators. The
// auto-instrumentation in quarkus-opentelemetry hooks both the
// outbound REST client AND the inbound JAX-RS endpoint, so each
// outbound HTTP span is paired with the correct server span.
@RegisterRestClient(configKey = "self")
public interface SelfClient {

    @GET
    @Path("/api/external/mock")
    Uni<Response> mock(
            @QueryParam("delayMs") long delayMs,
            @QueryParam("seq") int seq,
            @QueryParam("op") int op);

    @GET
    @Path("/api/dispatch/{channel}")
    Uni<Response> dispatch(
            @PathParam("channel") String channel,
            @QueryParam("delayMs") long delayMs);

    @GET
    @Path("/api/payments/history")
    Uni<Response> paymentsHistory(
            @QueryParam("customerId") long customerId,
            @QueryParam("limit") int limit);
}
