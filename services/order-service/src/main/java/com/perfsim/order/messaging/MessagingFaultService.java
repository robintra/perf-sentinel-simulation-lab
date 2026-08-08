package com.perfsim.order.messaging;

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
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;
import java.util.concurrent.TimeoutException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

@Service
public class MessagingFaultService {

    private static final String EXCHANGE = "perfsim.order-service";
    private static final String QUEUE = "perfsim.order-service";
    private static final String ROUTING_KEY = "order-service";
    private static final long CONFIRM_TIMEOUT_MS = 5_000;

    private final String directHost;
    private final int directPort;
    private final String slowHost;
    private final int slowPort;
    private final String toxiproxyApi;
    private final String username;
    private final String password;
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private final Tracer tracer = GlobalOpenTelemetry.getTracer(MessagingFaultService.class.getName());

    public MessagingFaultService(
            @Value("${RABBITMQ_HOST:rabbitmq.messaging.svc.cluster.local}") String directHost,
            @Value("${RABBITMQ_PORT:5672}") int directPort,
            @Value("${RABBITMQ_SLOW_HOST:toxiproxy.messaging.svc.cluster.local}") String slowHost,
            @Value("${RABBITMQ_SLOW_PORT:25672}") int slowPort,
            @Value("${TOXIPROXY_API:http://toxiproxy.messaging.svc.cluster.local:8474}")
                    String toxiproxyApi,
            @Value("${RABBITMQ_USERNAME}") String username,
            @Value("${RABBITMQ_PASSWORD}") String password) {
        this.directHost = directHost;
        this.directPort = directPort;
        this.slowHost = slowHost;
        this.slowPort = slowPort;
        this.toxiproxyApi = toxiproxyApi;
        this.username = username;
        this.password = password;
    }

    public Map<String, Object> publishSequentially(int messages) {
        try (Connection connection = newConnection(directHost, directPort);
                Channel channel = connection.createChannel()) {
            declareTopology(channel);
            channel.confirmSelect();
            for (int i = 0; i < messages; i++) {
                channel.basicPublish(
                        EXCHANGE, ROUTING_KEY, null, ("order-message-" + i).getBytes(UTF_8));
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

    public Map<String, Object> publishSlowly(long delayMs, int repeats) {
        try {
            updateLatency(delayMs);
            int confirmed = 0;
            try (Connection connection = newConnection(slowHost, slowPort);
                    Channel channel = connection.createChannel()) {
                declareTopology(channel);
                channel.confirmSelect();
                for (int i = 0; i < repeats; i++) {
                    Span span = tracer.spanBuilder(EXCHANGE + " send")
                            .setSpanKind(SpanKind.PRODUCER)
                            .setAttribute(AttributeKey.stringKey("messaging.system"), "rabbitmq")
                            .setAttribute(
                                    AttributeKey.stringKey("messaging.destination.name"), EXCHANGE)
                            .setAttribute(AttributeKey.stringKey("messaging.operation.type"), "send")
                            .startSpan();
                    try (Scope ignored = span.makeCurrent()) {
                        channel.basicPublish(
                                EXCHANGE,
                                ROUTING_KEY,
                                null,
                                ("slow-order-message-" + i).getBytes(UTF_8));
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
            return Map.of(
                    "published", repeats,
                    "confirmed", confirmed,
                    "delay_ms", delayMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while publishing through Toxiproxy", e);
        } catch (IOException | TimeoutException e) {
            throw new IllegalStateException("Slow RabbitMQ publication failed", e);
        }
    }

    private Connection newConnection(String host, int port) throws IOException, TimeoutException {
        ConnectionFactory factory = new ConnectionFactory();
        factory.setHost(host);
        factory.setPort(port);
        factory.setUsername(username);
        factory.setPassword(password);
        return factory.newConnection();
    }

    private static void declareTopology(Channel channel) throws IOException {
        channel.exchangeDeclare(EXCHANGE, "direct", true);
        channel.queueDeclare(QUEUE, true, false, false, Map.of("x-message-ttl", 60_000));
        channel.queueBind(QUEUE, EXCHANGE, ROUTING_KEY);
    }

    private void updateLatency(long delayMs) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(toxiproxyApi + "/proxies/rabbitmq-slow/toxics/latency_downstream"))
                .timeout(Duration.ofSeconds(5))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(
                        "{\"attributes\":{\"latency\":" + delayMs + ",\"jitter\":0}}"))
                .build();
        HttpResponse<Void> response =
                httpClient.send(request, HttpResponse.BodyHandlers.discarding());
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new IOException("Toxiproxy returned HTTP " + response.statusCode());
        }
    }
}
