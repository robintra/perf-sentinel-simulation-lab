package com.perfsim.helidonmpsvc.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "order_items", schema = "helidon_mp")
public class OrderItem {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    public Long id;

    @Column(name = "order_id", nullable = false)
    public Long orderId;

    @Column(nullable = false, length = 64)
    public String sku;

    @Column(nullable = false)
    public Integer quantity;

    @Column(name = "price_cents", nullable = false)
    public long priceCents;
}
