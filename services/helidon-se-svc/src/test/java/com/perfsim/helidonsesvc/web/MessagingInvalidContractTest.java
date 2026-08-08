package com.perfsim.helidonsesvc.web;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.perfsim.helidonsesvc.messaging.MessagingPublisher;
import io.helidon.webserver.WebServer;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class MessagingInvalidContractTest {

    private static final String SUCCESS_MARKER =
            "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0";

    @Test
    void rejectsSevenInvalidRequestsBeforeMessagingBoundaryAccess() throws Exception {
        AtomicInteger sequentialCalls = new AtomicInteger();
        AtomicInteger slowCalls = new AtomicInteger();
        MessagingPublisher publisher = new MessagingPublisher() {
            @Override
            public Map<String, Object> publishSequentially(int messages) {
                sequentialCalls.incrementAndGet();
                throw new AssertionError("RabbitMQ boundary invoked for invalid input");
            }

            @Override
            public Map<String, Object> publishSlowly(long delayMs, int repeats) {
                slowCalls.incrementAndGet();
                throw new AssertionError("Toxiproxy boundary invoked for invalid input");
            }
        };
        FaultRoutes routes = new FaultRoutes(null, null, "http://127.0.0.1:1", publisher);
        WebServer server = WebServer.builder()
                .host("127.0.0.1")
                .port(0)
                .routing(routing -> routing.register("/api/fault", routes))
                .build()
                .start();

        try {
            HttpClient client = HttpClient.newHttpClient();
            String[] paths = {
                "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
                "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
                "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported"
            };
            for (String path : paths) {
                HttpRequest request = HttpRequest.newBuilder()
                        .uri(URI.create("http://127.0.0.1:" + server.port() + path))
                        .POST(HttpRequest.BodyPublishers.noBody())
                        .build();
                assertEquals(400, client.send(request, HttpResponse.BodyHandlers.discarding()).statusCode());
            }

            assertEquals(0, sequentialCalls.get());
            assertEquals(0, slowCalls.get());
            System.out.println(SUCCESS_MARKER);
        } finally {
            server.stop();
        }
    }
}
