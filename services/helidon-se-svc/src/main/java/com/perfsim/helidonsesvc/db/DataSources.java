package com.perfsim.helidonsesvc.db;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import io.helidon.config.Config;
import javax.sql.DataSource;

/**
 * Builds the HikariCP {@link DataSource} from Helidon's config. Static
 * factory because helidon-se-svc deliberately stays CDI-less: the
 * service is a plain Java app driven by {@link com.perfsim.helidonsesvc.Main}.
 */
public final class DataSources {

    private DataSources() {}

    /**
     * Build a HikariCP DataSource. Reads YAML defaults from
     * {@code datasourceConfig} and overrides with env vars
     * {@code DB_URL} / {@code DB_USER} / {@code DB_PASSWORD} when
     * present — Helidon Config does not do {@code ${VAR}} expansion on
     * YAML sources, so the env-var resolution is handled in code.
     */
    public static HikariDataSource fromConfig(Config datasourceConfig) {
        HikariConfig hikari = new HikariConfig();
        hikari.setJdbcUrl(envOr("DB_URL", datasourceConfig.get("jdbc-url").asString().get()));
        hikari.setUsername(envOr("DB_USER", datasourceConfig.get("username").asString().get()));
        hikari.setPassword(envOr("DB_PASSWORD", datasourceConfig.get("password").asString().get()));
        hikari.setMaximumPoolSize(datasourceConfig.get("maximum-pool-size").asInt().orElse(10));
        hikari.setMinimumIdle(datasourceConfig.get("minimum-idle").asInt().orElse(2));
        hikari.setConnectionTimeout(datasourceConfig.get("connection-timeout").asLong().orElse(5000L));
        hikari.setPoolName("helidon-se-pool");
        return new HikariDataSource(hikari);
    }

    private static String envOr(String envKey, String fallback) {
        String v = System.getenv(envKey);
        return (v == null || v.isBlank()) ? fallback : v;
    }
}
