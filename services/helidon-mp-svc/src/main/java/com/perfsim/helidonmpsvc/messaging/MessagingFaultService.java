package com.perfsim.helidonmpsvc.messaging;

import static java.nio.charset.StandardCharsets.UTF_8;

import com.rabbitmq.client.Channel;
import com.rabbitmq.client.Connection;
import com.rabbitmq.client.ConnectionFactory;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import jakarta.enterprise.context.ApplicationScoped;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;
import java.util.concurrent.TimeoutException;

@ApplicationScoped
public class MessagingFaultService implements MessagingPublisher {

    private static final String EXCHANGE = "perfsim.helidon-mp-svc";
    private static final String QUEUE = "perfsim.helidon-mp-svc";
    private static final String ROUTING_KEY = "helidon-mp-svc";
    private static final long CONFIRM_TIMEOUT_MS = 5_000;
    private static final int NETWORK_MARGIN_MS = 5_000;

    private final String directHost;
    private final int directPort;
    private final String slowHost;
    private final int slowPort;
    private final String toxiproxyApi;
    private final String username;
    private final String password;
    private final HttpClient httpClient;
    private final Tracer tracer;

    public MessagingFaultService() {
        directHost = envOr("RABBITMQ_HOST", "rabbitmq.messaging.svc.cluster.local");
        directPort = envOrInt("RABBITMQ_PORT", 5_672);
        slowHost = envOr("RABBITMQ_SLOW_HOST", "toxiproxy.messaging.svc.cluster.local");
        slowPort = envOrInt("RABBITMQ_SLOW_PORT", 25_672);
        toxiproxyApi = envOr("TOXIPROXY_API", "http://toxiproxy.messaging.svc.cluster.local:8474");
        username = System.getenv("RABBITMQ_USERNAME");
        password = System.getenv("RABBITMQ_PASSWORD");
        httpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        tracer = GlobalOpenTelemetry.getTracer(MessagingFaultService.class.getName());
    }

    @Override
    public Map<String, Object> publishSequentially(int messages) {
        String configuredUsername = requireCredential("RABBITMQ_USERNAME", username);
        String configuredPassword = requireCredential("RABBITMQ_PASSWORD", password);
        try (Connection connection = newConnection(
                        directHost, directPort, 0, configuredUsername, configuredPassword);
                Channel channel = connection.createChannel()) {
            declareTopology(channel);
            channel.confirmSelect();
            for (int i = 0; i < messages; i++) {
                channel.basicPublish(
                        EXCHANGE, ROUTING_KEY, null, ("helidon-mp-message-" + i).getBytes(UTF_8));
            }
            channel.waitForConfirmsOrDie(CONFIRM_TIMEOUT_MS);
            return Map.of("published", messages, "confirmed", messages);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while awaiting RabbitMQ confirms", e);
        } catch (IOException | TimeoutException e) {
            throw new IllegalStateException("RabbitMQ publication failed", e);
        }
    }

    @Override
    public Map<String, Object> publishSlowly(long delayMs, int repeats) {
        String configuredUsername = requireCredential("RABBITMQ_USERNAME", username);
        String configuredPassword = requireCredential("RABBITMQ_PASSWORD", password);
        try {
            updateLatency(delayMs);
            int confirmed = 0;
            try (Connection connection = newConnection(
                            slowHost, slowPort, delayMs, configuredUsername, configuredPassword);
                    Channel channel = connection.createChannel()) {
                declareTopology(channel);
                channel.confirmSelect();
                for (int i = 0; i < repeats; i++) {
                    Span span = tracer.spanBuilder(EXCHANGE + " send")
                            .setSpanKind(SpanKind.PRODUCER)
                            .setAttribute(AttributeKey.stringKey("messaging.system"), "rabbitmq")
                            .setAttribute(AttributeKey.stringKey("messaging.destination.name"), EXCHANGE)
                            .setAttribute(AttributeKey.stringKey("messaging.operation.type"), "send")
                            .startSpan();
                    try (Scope ignored = span.makeCurrent()) {
                        channel.basicPublish(
                                EXCHANGE,
                                ROUTING_KEY,
                                null,
                                ("slow-helidon-mp-message-" + i).getBytes(UTF_8));
                        channel.waitForConfirmsOrDie(delayMs + CONFIRM_TIMEOUT_MS);
                        confirmed++;
                    } catch (Exception e) {
                        span.recordException(e);
                        span.setStatus(StatusCode.ERROR);
                        throw e;
                    } finally {
                        span.end();
                    }
                }
            }
            return Map.of("published", repeats, "confirmed", confirmed, "delay_ms", delayMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while publishing through Toxiproxy", e);
        } catch (IOException | TimeoutException e) {
            throw new IllegalStateException("Slow RabbitMQ publication failed", e);
        }
    }

    private Connection newConnection(
            String host, int port, long downstreamDelayMs, String configuredUsername, String configuredPassword)
            throws IOException, TimeoutException {
        ConnectionFactory factory = new ConnectionFactory();
        factory.setHost(host);
        factory.setPort(port);
        factory.setUsername(configuredUsername);
        factory.setPassword(configuredPassword);
        int responseTimeoutMs = Math.toIntExact(downstreamDelayMs + NETWORK_MARGIN_MS);
        factory.setConnectionTimeout((int) CONFIRM_TIMEOUT_MS);
        factory.setHandshakeTimeout(downstreamDelayMs == 0
                ? (int) CONFIRM_TIMEOUT_MS
                : Math.toIntExact(2L * responseTimeoutMs + 1));
        factory.setChannelRpcTimeout(responseTimeoutMs);
        factory.setShutdownTimeout(responseTimeoutMs);
        return factory.newConnection();
    }

    private static String requireCredential(String name, String value) {
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required");
        }
        return value;
    }

    private static void declareTopology(Channel channel) throws IOException {
        channel.exchangeDeclare(EXCHANGE, "direct", true);
        channel.queueDeclare(QUEUE, true, false, false, Map.of("x-message-ttl", 60_000));
        channel.queueBind(QUEUE, EXCHANGE, ROUTING_KEY);
    }

    private void updateLatency(long delayMs) throws IOException, InterruptedException {
        String updatePath = "/proxies/rabbitmq-slow/toxics/latency_downstream";
        String attributes = "{\"attributes\":{\"latency\":" + delayMs + ",\"jitter\":0}}";
        HttpResponse<Void> response = sendToxiproxy(updatePath, attributes);
        if (response.statusCode() == 404) {
            String createBody = "{\"name\":\"latency_downstream\","
                    + "\"type\":\"latency\",\"stream\":\"downstream\","
                    + "\"attributes\":{\"latency\":" + delayMs + ",\"jitter\":0}}";
            response = sendToxiproxy("/proxies/rabbitmq-slow/toxics", createBody);
            if (response.statusCode() == 409) {
                response = sendToxiproxy(updatePath, attributes);
            }
        }
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new IOException("Toxiproxy returned HTTP " + response.statusCode());
        }
    }

    private HttpResponse<Void> sendToxiproxy(String path, String body)
            throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(toxiproxyApi + path))
                .timeout(Duration.ofSeconds(5))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        return httpClient.send(request, HttpResponse.BodyHandlers.discarding());
    }

    private static String envOr(String name, String fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : value;
    }

    private static int envOrInt(String name, int fallback) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? fallback : Integer.parseInt(value);
    }
}
