package com.perfsim.order.web;

import com.perfsim.order.domain.Order;
import com.perfsim.order.domain.OrderRepository;
import jakarta.transaction.Transactional;
import java.util.List;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
@RequestMapping("/api")
public class OrderController {

    private final OrderRepository orders;
    private final RestClient paymentClient;

    public OrderController(OrderRepository orders, RestClient paymentClient) {
        this.orders = orders;
        this.paymentClient = paymentClient;
    }

    @GetMapping("/orders/{id}")
    @Transactional
    public ResponseEntity<Map<String, Object>> getOrder(@PathVariable Long id) {
        return orders.findById(id)
                .<Map<String, Object>>map(o -> Map.of(
                        "id", o.getId(),
                        "customer", o.getCustomer(),
                        "status", o.getStatus(),
                        "items_count", o.getItems().size()))
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    @GetMapping("/orders")
    public List<Map<String, Object>> listPending() {
        return orders.findFirst50ByStatus("PENDING").stream()
                .<Map<String, Object>>map(o -> Map.of(
                        "id", o.getId(),
                        "customer", o.getCustomer(),
                        "total_cents", o.getTotalCents()))
                .toList();
    }

    @PostMapping("/checkout/{orderId}")
    @Transactional
    public ResponseEntity<Map<String, Object>> checkout(@PathVariable Long orderId) {
        Order order = orders.findById(orderId).orElseThrow();
        Map<?, ?> chargeResp = paymentClient
                .post()
                .uri("/api/charge?orderId={id}&amountCents={amt}", orderId, order.getTotalCents())
                .retrieve()
                .body(Map.class);
        order.setStatus("PAID");
        orders.save(order);
        return ResponseEntity.ok(Map.<String, Object>of(
                "orderId", orderId,
                "status", order.getStatus(),
                "payment", chargeResp));
    }
}
