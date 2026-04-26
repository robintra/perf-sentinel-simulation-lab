package com.perfsim.payment.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;

@Entity
@Table(name = "payments", schema = "payments")
public class Payment {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "order_id", nullable = false)
    private Long orderId;

    @Column(name = "customer_id", nullable = false)
    private Long customerId;

    @Column(name = "amount_cents", nullable = false)
    private long amountCents;

    @Column(nullable = false)
    private String status = "PENDING";

    @Column(name = "created_at", nullable = false)
    private OffsetDateTime createdAt = OffsetDateTime.now();

    public Payment() {}

    public Payment(Long orderId, Long customerId, long amountCents, String status) {
        this.orderId = orderId;
        this.customerId = customerId;
        this.amountCents = amountCents;
        this.status = status;
    }

    public Long getId() {
        return id;
    }

    public Long getOrderId() {
        return orderId;
    }

    public Long getCustomerId() {
        return customerId;
    }

    public long getAmountCents() {
        return amountCents;
    }

    public String getStatus() {
        return status;
    }

    public OffsetDateTime getCreatedAt() {
        return createdAt;
    }
}
