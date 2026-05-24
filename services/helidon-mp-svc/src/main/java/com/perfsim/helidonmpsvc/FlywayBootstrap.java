package com.perfsim.helidonmpsvc;

import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.context.Initialized;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;

/**
 * CDI startup observer that runs Flyway migrations against the
 * `helidonMpDataSource`. Helidon MP, unlike Quarkus, has no
 * "migrate-at-start" toggle on the Flyway extension; the simplest
 * portable hook is an @Initialized(ApplicationScoped.class) observer.
 * Priority 100 fires before any JAX-RS resource sees its first
 * request, so the schema is in place by the time the fault endpoints
 * land their first SELECT.
 */
@ApplicationScoped
public class FlywayBootstrap {

    @Inject
    DataSource dataSource;

    public void onStart(@Observes @Priority(100) @Initialized(ApplicationScoped.class) Object init) {
        Flyway flyway = Flyway.configure()
                .dataSource(dataSource)
                .schemas("helidon_mp")
                .defaultSchema("helidon_mp")
                .baselineOnMigrate(true)
                .locations("classpath:db/migration")
                .load();
        flyway.migrate();
    }
}
