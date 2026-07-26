package com.perfsim.order.job;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.transaction.Transactional;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Two scheduled jobs issuing the SAME statement, the only non-HTTP entry point
 * in the lab.
 *
 * <p>Findings raised here reach the detectors with no inbound HTTP span
 * anywhere up the parent chain, which is the case perf-sentinel's code-frame
 * endpoint fallback exists for. Two jobs rather than one on purpose: the
 * acknowledgment signature is {@code type : service : endpoint : hash(template)},
 * so two distinct jobs sharing a statement must still get distinct endpoints or
 * acknowledging one silently hides the other.
 *
 * <p>Opt-in, off by default: a permanently running background N+1 in a core
 * service would shift the finding baseline of every scenario and every release
 * gate run. Enable with {@code PERFSIM_SCHEDULEDJOBS_ENABLED=true}.
 */
@Component
@ConditionalOnProperty(name = "perfsim.scheduled-jobs.enabled", havingValue = "true")
public class ScheduledJobs {

    @PersistenceContext
    private EntityManager em;

    @Scheduled(fixedDelayString = "${perfsim.scheduled-jobs.delay-ms:20000}")
    @Transactional
    public void reconcileOrders() {
        countItemsPerOrder(12);
    }

    @Scheduled(fixedDelayString = "${perfsim.scheduled-jobs.delay-ms:20000}",
               initialDelay = 10_000)
    @Transactional
    public void archiveOrders() {
        countItemsPerOrder(12);
    }

    /**
     * Lab-only: the literal is concatenated into the SQL string so the OTel JDBC
     * instrumentation records distinct statements, matching what
     * {@code FaultController} does for the HTTP-triggered N+1. Never copy this
     * pattern into any code path that handles untrusted input.
     */
    private void countItemsPerOrder(int orders) {
        for (int orderId = 1; orderId <= orders; orderId++) {
            em.createNativeQuery(
                            "SELECT count(*) FROM orders.order_items WHERE order_id = "
                                    + orderId)
                    .getSingleResult();
        }
    }
}
