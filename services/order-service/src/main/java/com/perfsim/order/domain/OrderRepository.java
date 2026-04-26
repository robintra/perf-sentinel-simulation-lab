package com.perfsim.order.domain;

import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

public interface OrderRepository extends JpaRepository<Order, Long> {

    List<Order> findFirst50ByStatus(String status);

    @Query(value = "SELECT pg_sleep(:delaySeconds), * FROM orders.orders ORDER BY id LIMIT 1",
           nativeQuery = true)
    Object slowQuery(double delaySeconds);

    @Query(value = "SELECT pg_sleep(:delaySeconds), * FROM orders.orders ORDER BY id OFFSET :offset LIMIT 1",
           nativeQuery = true)
    Object slowQueryDistinct(double delaySeconds, int offset);
}
