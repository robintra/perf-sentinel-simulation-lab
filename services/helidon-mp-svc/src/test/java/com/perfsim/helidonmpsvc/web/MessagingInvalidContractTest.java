package com.perfsim.helidonmpsvc.web;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.perfsim.helidonmpsvc.FlywayBootstrap;
import com.perfsim.helidonmpsvc.messaging.MessagingPublisher;
import jakarta.enterprise.inject.Instance;
import jakarta.ws.rs.client.Entity;
import jakarta.ws.rs.core.Application;
import jakarta.ws.rs.core.Response;
import java.lang.reflect.Proxy;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import javax.sql.DataSource;
import org.glassfish.jersey.server.ResourceConfig;
import org.glassfish.jersey.test.JerseyTest;
import org.glassfish.jersey.test.inmemory.InMemoryTestContainerFactory;
import org.glassfish.jersey.test.spi.TestContainerFactory;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class MessagingInvalidContractTest extends JerseyTest {

    private static final String SUCCESS_MARKER =
            "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0";

    private final AtomicInteger sequentialCalls = new AtomicInteger();
    private final AtomicInteger slowCalls = new AtomicInteger();

    @Override
    protected Application configure() {
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
        return new ResourceConfig().register(new FaultResource(publisher));
    }

    @Override
    protected TestContainerFactory getTestContainerFactory() {
        return new InMemoryTestContainerFactory();
    }

    @BeforeEach
    void startJersey() throws Exception {
        super.setUp();
    }

    @AfterEach
    void stopJersey() throws Exception {
        super.tearDown();
    }

    @Test
    void rejectsSevenInvalidRequestsBeforeMessagingBoundaryAccess() {
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
            try (Response response = client()
                    .target(getBaseUri().resolve(path.substring(1)))
                    .request()
                    .post(Entity.text(""))) {
                assertEquals(400, response.getStatus(), path);
            }
        }

        assertEquals(0, sequentialCalls.get());
        assertEquals(0, slowCalls.get());
        System.out.println(SUCCESS_MARKER);
    }

    @Test
    void disabledFlywayDoesNotResolveDataSource() {
        AtomicInteger getCalls = new AtomicInteger();
        @SuppressWarnings("unchecked")
        Instance<DataSource> dataSource = (Instance<DataSource>) Proxy.newProxyInstance(
                getClass().getClassLoader(),
                new Class<?>[] {Instance.class},
                (proxy, method, args) -> {
                    if (method.getName().equals("get")) {
                        getCalls.incrementAndGet();
                        throw new AssertionError("DataSource resolved while Flyway was disabled");
                    }
                    return null;
                });

        new FlywayBootstrap(false, dataSource).onStart(new Object());

        assertEquals(0, getCalls.get());
    }
}
