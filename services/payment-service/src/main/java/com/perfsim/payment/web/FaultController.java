package com.perfsim.payment.web;

import com.perfsim.payment.domain.PaymentRepository;
import com.perfsim.shared.BaseFaultController;
import com.perfsim.shared.FaultResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
@RequestMapping("/api/fault")
public class FaultController extends BaseFaultController {

    private final PaymentRepository payments;
    private final RestClient notificationClient;

    @PersistenceContext
    private EntityManager em;

    public FaultController(PaymentRepository payments, RestClient notificationClient) {
        this.payments = payments;
        this.notificationClient = notificationClient;
    }

    @Override
    protected String serviceName() {
        return "payment-service";
    }

    @PostMapping("/redundant-sql")
    public ResponseEntity<FaultResponse> redundantSql(
            @RequestParam(defaultValue = "10") int repeats) {
        return runFault(
                "redundant_sql",
                Map.of("repeats", repeats),
                () -> {
                    // Lab-only: same SQL string with the same literal value
                    // every iteration. Detector flags as redundant_sql when
                    // occurrences >= threshold and distinct_params < threshold.
                    // Never copy this concatenated-literal pattern into any
                    // code path that handles untrusted input.
                    int rows = 0;
                    for (int i = 0; i < repeats; i++) {
                        Object count = em.createNativeQuery(
                                        "SELECT count(*) FROM payments.payments "
                                                + "WHERE customer_id = 1")
                                .getSingleResult();
                        if (count instanceof Number n) {
                            rows += n.intValue();
                        }
                    }
                    return Map.of("queries_made", repeats, "rows_seen", rows);
                });
    }

    @PostMapping("/slow-http")
    public ResponseEntity<FaultResponse> slowHttp(
            @RequestParam(defaultValue = "600") long delayMs,
            @RequestParam(defaultValue = "6") int repeats) {
        return runFault(
                "slow_http",
                Map.of("delayMs", delayMs, "repeats", repeats),
                () -> {
                    int ok = 0;
                    for (int i = 0; i < repeats; i++) {
                        notificationClient
                                .get()
                                .uri("/api/external/mock?delayMs={d}", delayMs)
                                .retrieve()
                                .toBodilessEntity();
                        ok++;
                    }
                    return Map.of("calls_made", repeats, "calls_ok", ok, "delay_ms", delayMs);
                });
    }
}
