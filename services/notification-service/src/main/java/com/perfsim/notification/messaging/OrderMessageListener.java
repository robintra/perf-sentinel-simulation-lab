package com.perfsim.notification.messaging;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.transaction.Transactional;
import java.util.Map;
import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.DirectExchange;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.context.annotation.Bean;
import org.springframework.stereotype.Component;

/**
 * The lab's only message consumer: one N+1 read per message taken from the
 * queue order-service publishes to.
 *
 * <p>Under the OTel javaagent the spring-rabbit instrumentation wraps the
 * listener in a CONSUMER span whose parent is the publisher's span carried in
 * the AMQP headers. On this service's side of the boundary that CONSUMER span
 * is the outermost ancestor of the reads, so the finding's source_endpoint is
 * the consumer destination ({@code rabbitmq order-service}, the received
 * routing key) rather than an HTTP route. A listener inside order-service
 * would sit under the publishing HTTP route, which wins by design. It only
 * runs under messaging traffic.
 */
@Component
public class OrderMessageListener {

    static final String EXCHANGE = "perfsim.order-service";
    static final String QUEUE = "perfsim.order-service";
    static final String ROUTING_KEY = "order-service";
    private static final int CUSTOMERS = 12;

    @PersistenceContext
    private EntityManager em;

    // The same topology order-service declares on publish, argument for
    // argument: RabbitMQ rejects a redeclaration whose arguments differ.
    @Bean
    Queue orderQueue() {
        return new Queue(QUEUE, true, false, false, Map.of("x-message-ttl", 60_000));
    }

    @Bean
    DirectExchange orderExchange() {
        return new DirectExchange(EXCHANGE, true, false);
    }

    @Bean
    Binding orderBinding(Queue orderQueue, DirectExchange orderExchange) {
        return BindingBuilder.bind(orderQueue).to(orderExchange).with(ROUTING_KEY);
    }

    // Raw Message: the producer publishes an untyped body with null properties,
    // a converted parameter would fail before the reads run. EntityManager
    // rather than the repository keeps the spring-data repository span (which
    // carries code.*) off the chain, otherwise the frame would win.
    @RabbitListener(queues = QUEUE)
    @Transactional
    public void onOrderMessage(Message message) {
        // Lab-only: the literal is concatenated into the SQL string so the
        // OTel JDBC instrumentation records distinct statements, as the
        // HTTP-triggered N+1 does. Never copy this pattern into any code path
        // that handles untrusted input.
        for (int customerId = 1; customerId <= CUSTOMERS; customerId++) {
            em.createNativeQuery(
                            "SELECT count(*) FROM notifications.notifications WHERE customer_id = "
                                    + customerId)
                    .getSingleResult();
        }
    }
}
