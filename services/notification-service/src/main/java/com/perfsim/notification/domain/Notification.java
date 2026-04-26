package com.perfsim.notification.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;

@Entity
@Table(name = "notifications", schema = "notifications")
public class Notification {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "payment_id", nullable = false)
    private Long paymentId;

    @Column(name = "customer_id", nullable = false)
    private Long customerId;

    @Column(nullable = false)
    private String channel = "EMAIL";

    @Column(nullable = false)
    private String message;

    @Column(name = "sent_at", nullable = false)
    private OffsetDateTime sentAt = OffsetDateTime.now();

    public Notification() {}

    public Notification(Long paymentId, Long customerId, String message) {
        this.paymentId = paymentId;
        this.customerId = customerId;
        this.message = message;
    }

    public Long getId() {
        return id;
    }

    public Long getPaymentId() {
        return paymentId;
    }

    public Long getCustomerId() {
        return customerId;
    }

    public String getChannel() {
        return channel;
    }

    public String getMessage() {
        return message;
    }

    public OffsetDateTime getSentAt() {
        return sentAt;
    }
}
