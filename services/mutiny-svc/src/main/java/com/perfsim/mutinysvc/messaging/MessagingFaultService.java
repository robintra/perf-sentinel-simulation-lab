package com.perfsim.mutinysvc.messaging;

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
import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.infrastructure.Infrastructure;
import jakarta.enterprise.context.ApplicationScoped;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.TimeoutException;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class MessagingFaultService {

    private static final String EXCHANGE = "perfsim.mutiny-svc";
    private static final String QUEUE = "perfsim.mutiny-svc";
    private static final String ROUTING_KEY = "mutiny-svc";
    private static final long CONFIRM_TIMEOUT_MS = 5_000;
    private static final int NETWORK_MARGIN_MS = 5_000;

    private final String directHost;
    private final int directPort;
    private final String slowHost;
    private final int slowPort;
    private final String toxiproxyApi;
    private final Optional<String> username;
    private final Optional<String> password;
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private final Tracer tracer = GlobalOpenTelemetry.getTracer(MessagingFaultService.class.getName());

    public MessagingFaultService(
            @ConfigProperty(name = "RABBITMQ_HOST", defaultValue = "rabbitmq.messaging.svc.cluster.local")
                    String directHost,
            @ConfigProperty(name = "RABBITMQ_PORT", defaultValue = "5672") int directPort,
            @ConfigProperty(name = "RABBITMQ_SLOW_HOST", defaultValue = "toxiproxy.messaging.svc.cluster.local")
                    String slowHost,
            @ConfigProperty(name = "RABBITMQ_SLOW_PORT", defaultValue = "25672") int slowPort,
            @ConfigProperty(name = "TOXIPROXY_API", defaultValue = "http://toxiproxy.messaging.svc.cluster.local:8474")
                    String toxiproxyApi,
            @ConfigProperty(name = "RABBITMQ_USERNAME") Optional<String> username,
            @ConfigProperty(name = "RABBITMQ_PASSWORD") Optional<String> password) {
        this.directHost = directHost;
        this.directPort = directPort;
        this.slowHost = slowHost;
        this.slowPort = slowPort;
        this.toxiproxyApi = toxiproxyApi;
        this.username = username;
        this.password = password;
    }

    public Uni<Map<String, Object>> publishSequentially(int messages) {
        return Uni.createFrom()
                .item(() -> publishSequentiallyBlocking(messages))
                .runSubscriptionOn(Infrastructure.getDefaultWorkerPool());
    }

    public Uni<Map<String, Object>> publishSlowly(long delayMs, int repeats) {
        return Uni.createFrom()
                .item(() -> publishSlowlyBlocking(delayMs, repeats))
                .runSubscriptionOn(Infrastructure.getDefaultWorkerPool());
    }

    private Map<String, Object> publishSequentiallyBlocking(int messages) {
        String configuredUsername = requireCredential("RABBITMQ_USERNAME", username);
        String configuredPassword = requireCredential("RABBITMQ_PASSWORD", password);
        try (Connection connection = newConnection(
                        directHost, directPort, 0, configuredUsername, configuredPassword);
                Channel channel = connection.createChannel()) {
            declareTopology(channel);
            channel.confirmSelect();
            for (int i = 0; i < messages; i++) {
                Span span = startProducerSpan();
                try (Scope ignored = span.makeCurrent()) {
                    channel.basicPublish(
                            EXCHANGE, ROUTING_KEY, null, ("mutiny-message-" + i).getBytes(UTF_8));
                } catch (Exception e) {
                    span.recordException(e);
                    span.setStatus(StatusCode.ERROR);
                    throw e;
                } finally {
                    span.end();
                }
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

    private Map<String, Object> publishSlowlyBlocking(long delayMs, int repeats) {
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
                    Span span = startProducerSpan();
                    try (Scope ignored = span.makeCurrent()) {
                        channel.basicPublish(
                                EXCHANGE,
                                ROUTING_KEY,
                                null,
                                ("slow-mutiny-message-" + i).getBytes(UTF_8));
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

    private Span startProducerSpan() {
        return tracer.spanBuilder(EXCHANGE + " send")
                .setSpanKind(SpanKind.PRODUCER)
                .setAttribute(AttributeKey.stringKey("messaging.system"), "rabbitmq")
                .setAttribute(AttributeKey.stringKey("messaging.destination.name"), EXCHANGE)
                .setAttribute(AttributeKey.stringKey("messaging.operation.type"), "send")
                .startSpan();
    }

    private Connection newConnection(
            String host, int port, long downstreamDelayMs, String username, String password)
            throws IOException, TimeoutException {
        ConnectionFactory factory = new ConnectionFactory();
        factory.setHost(host);
        factory.setPort(port);
        factory.setUsername(username);
        factory.setPassword(password);
        int responseTimeoutMs = Math.toIntExact(downstreamDelayMs + NETWORK_MARGIN_MS);
        factory.setConnectionTimeout((int) CONFIRM_TIMEOUT_MS);
        factory.setHandshakeTimeout(downstreamDelayMs == 0
                ? (int) CONFIRM_TIMEOUT_MS
                : Math.toIntExact(2L * responseTimeoutMs + 1));
        factory.setChannelRpcTimeout(responseTimeoutMs);
        factory.setShutdownTimeout(responseTimeoutMs);
        return factory.newConnection();
    }

    private static String requireCredential(String name, Optional<String> value) {
        return value.filter(credential -> !credential.isBlank())
                .orElseThrow(() -> new IllegalStateException(name + " is required"));
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
}
