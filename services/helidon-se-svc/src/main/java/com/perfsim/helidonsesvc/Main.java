package com.perfsim.helidonsesvc;

import com.perfsim.helidonsesvc.db.DataSources;
import com.perfsim.helidonsesvc.messaging.MessagingFaultService;
import com.perfsim.helidonsesvc.messaging.MessagingPublisher;
import com.perfsim.helidonsesvc.web.BusinessRoutes;
import com.perfsim.helidonsesvc.web.FaultRoutes;
import com.zaxxer.hikari.HikariDataSource;
import io.helidon.config.Config;
import io.helidon.http.media.jsonp.JsonpSupport;
import io.helidon.webserver.WebServer;
import java.net.http.HttpClient;
import java.time.Duration;
import org.flywaydb.core.Flyway;

/**
 * helidon-se-svc entry point. Plain Java main: no CDI, no annotation
 * scanning. Builds the HikariCP DataSource, runs Flyway migrations,
 * builds the JDK stdlib HttpClient (self-loop) and wires the two
 * route handlers into the Helidon SE WebServer.
 *
 * <p>The outbound HTTP client is {@link java.net.http.HttpClient}, not
 * Helidon WebClient. See the FaultRoutes Javadoc for the rationale —
 * short version: the OTel Java agent v2.27 has no Helidon WebClient
 * instrumentation and Helidon's own tracing module conflicts with the
 * agent's {@code GlobalOpenTelemetry}. The JDK client is covered by
 * the agent's {@code io.opentelemetry.java-http-client} scope.</p>
 */
public final class Main {

    private Main() {}

    public static void main(String[] args) {
        Config config = Config.create();

        HikariDataSource dataSource = DataSources.fromConfig(config.get("datasource"));

        Flyway flyway = Flyway.configure()
                .dataSource(dataSource)
                .schemas("helidon_se")
                .defaultSchema("helidon_se")
                .baselineOnMigrate(true)
                .locations("classpath:db/migration")
                .load();
        flyway.migrate();

        String selfBaseUrl = System.getenv("SELF_BASE_URL");
        if (selfBaseUrl == null || selfBaseUrl.isBlank()) {
            selfBaseUrl = config.get("self.base-url").asString().orElse("http://localhost:8085");
        }
        HttpClient httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();

        MessagingPublisher messagingPublisher = new MessagingFaultService(
                envOr("RABBITMQ_HOST", "rabbitmq.messaging.svc.cluster.local"),
                envOrInt("RABBITMQ_PORT", 5672),
                envOr("RABBITMQ_SLOW_HOST", "toxiproxy.messaging.svc.cluster.local"),
                envOrInt("RABBITMQ_SLOW_PORT", 25672),
                envOr("TOXIPROXY_API", "http://toxiproxy.messaging.svc.cluster.local:8474"),
                envOr("RABBITMQ_USERNAME", null),
                envOr("RABBITMQ_PASSWORD", null));
        FaultRoutes faultRoutes = new FaultRoutes(dataSource, httpClient, selfBaseUrl, messagingPublisher);
        BusinessRoutes businessRoutes = new BusinessRoutes(dataSource);

        // Helidon Config does not expand ${VAR} on YAML sources, so
        // env-var overrides are resolved in code (same pattern as
        // DataSources.fromConfig). HTTP_PORT / HTTP_HOST let the helm
        // chart retarget the listener via deployment env without
        // touching application.yaml.
        int httpPort = envOrInt("HTTP_PORT", config.get("server.port").asInt().orElse(8085));
        String httpHost = envOr("HTTP_HOST", config.get("server.host").asString().orElse("0.0.0.0"));

        WebServer.builder()
                .port(httpPort)
                .host(httpHost)
                .mediaContext(mc -> mc.addMediaSupport(JsonpSupport.create()))
                .routing(routing -> routing
                        // Lightweight liveness/readiness, wired by the
                        // deployment's probes. Sufficient for the lab —
                        // Helidon SE has an ObserveFeature module for
                        // richer health checks, kept out of this minimal
                        // service to limit dependencies. application/json
                        // content-type matches the multistack convention
                        // (helidon-mp/quarkus/mutiny all respond JSON).
                        .get("/health/live", Main::healthHandler)
                        .get("/health/ready", Main::healthHandler)
                        .register("/api/fault", faultRoutes)
                        .register("/api", businessRoutes))
                .build()
                .start();
    }

    private static void healthHandler(
            io.helidon.webserver.http.ServerRequest req,
            io.helidon.webserver.http.ServerResponse res) {
        res.headers().contentType(io.helidon.http.HttpMediaType.create("application/json"));
        res.send("{\"status\":\"UP\"}");
    }

    private static String envOr(String envKey, String fallback) {
        String v = System.getenv(envKey);
        return (v == null || v.isBlank()) ? fallback : v;
    }

    private static int envOrInt(String envKey, int fallback) {
        String v = System.getenv(envKey);
        if (v == null || v.isBlank()) {
            return fallback;
        }
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            throw new IllegalStateException("invalid integer for env " + envKey + ": " + v, e);
        }
    }
}
