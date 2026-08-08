package com.perfsim.order.messaging;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class MessagingFaultServiceTest {

    @Test
    void createsMissingLatencyToxicBeforeConnectingToRabbitMq() throws Exception {
        List<String> requests = new ArrayList<>();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext(
                "/proxies/rabbitmq-slow/toxics/latency_downstream",
                exchange -> {
                    requests.add(exchange.getRequestURI().getPath());
                    exchange.sendResponseHeaders(404, -1);
                    exchange.close();
                });
        server.createContext(
                "/proxies/rabbitmq-slow/toxics",
                exchange -> {
                    requests.add(new String(
                            exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
                    exchange.sendResponseHeaders(200, -1);
                    exchange.close();
                });
        server.start();
        try {
            MessagingFaultService service = new MessagingFaultService(
                    "127.0.0.1",
                    1,
                    "127.0.0.1",
                    1,
                    "http://127.0.0.1:" + server.getAddress().getPort(),
                    "user",
                    "password");

            assertThrows(IllegalStateException.class, () -> service.publishSlowly(600, 3));

            assertEquals(2, requests.size());
            String createBody = requests.get(1);
            assertTrue(createBody.contains("\"name\":\"latency_downstream\""));
            assertTrue(createBody.contains("\"type\":\"latency\""));
            assertTrue(createBody.contains("\"stream\":\"downstream\""));
            assertTrue(createBody.contains("\"latency\":600"));
            assertTrue(createBody.contains("\"jitter\":0"));
        } finally {
            server.stop(0);
        }
    }
}
