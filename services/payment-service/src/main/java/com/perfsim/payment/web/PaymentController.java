package com.perfsim.payment.web;

import com.perfsim.payment.domain.Payment;
import com.perfsim.payment.domain.PaymentRepository;
import jakarta.transaction.Transactional;
import java.util.List;
import java.util.Map;
import org.springframework.data.domain.Limit;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
@RequestMapping("/api")
public class PaymentController {

    private final PaymentRepository payments;
    private final RestClient notificationClient;

    public PaymentController(PaymentRepository payments, RestClient notificationClient) {
        this.payments = payments;
        this.notificationClient = notificationClient;
    }

    @PostMapping("/charge")
    @Transactional
    public ResponseEntity<Map<String, Object>> charge(
            @RequestParam Long orderId,
            @RequestParam(defaultValue = "1") Long customerId,
            @RequestParam long amountCents) {
        Payment p = new Payment(orderId, customerId, amountCents, "PAID");
        payments.save(p);
        notificationClient
                .post()
                .uri("/api/notify?paymentId={pid}&customerId={cid}", p.getId(), customerId)
                .retrieve()
                .toBodilessEntity();
        return ResponseEntity.ok(Map.<String, Object>of(
                "paymentId", p.getId(),
                "orderId", orderId,
                "amountCents", amountCents,
                "status", p.getStatus()));
    }

    @GetMapping("/payments/history")
    public List<Map<String, Object>> history(
            @RequestParam(defaultValue = "1") Long customerId,
            @RequestParam(defaultValue = "10") int limit) {
        return payments.findByCustomerIdOrderByCreatedAtDesc(customerId, Limit.of(limit)).stream()
                .<Map<String, Object>>map(p -> Map.of(
                        "id", p.getId(),
                        "amount_cents", p.getAmountCents(),
                        "status", p.getStatus()))
                .toList();
    }
}
