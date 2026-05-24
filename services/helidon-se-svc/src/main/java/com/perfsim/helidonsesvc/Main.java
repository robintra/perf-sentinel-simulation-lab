package com.perfsim.helidonsesvc;

import com.perfsim.helidonsesvc.db.DataSources;
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

        FaultRoutes faultRoutes = new FaultRoutes(dataSource, httpClient, selfBaseUrl);
        BusinessRoutes businessRoutes = new BusinessRoutes(dataSource);

        WebServer.builder()
                .config(config.get("server"))
                .mediaContext(mc -> mc.addMediaSupport(JsonpSupport.create()))
                .routing(routing -> routing
                        // Lightweight liveness/readiness, wired by the
                        // deployment's probes. Sufficient for the lab —
                        // Helidon SE has an ObserveFeature module for
                        // richer health checks, kept out of this minimal
                        // service to limit dependencies.
                        .get("/health/live", (req, res) -> res.send("{\"status\":\"UP\"}"))
                        .get("/health/ready", (req, res) -> res.send("{\"status\":\"UP\"}"))
                        .register("/api/fault", faultRoutes)
                        .register("/api", businessRoutes))
                .build()
                .start();
    }
}
