package com.perfsim.payment.domain;

import java.util.List;
import org.springframework.data.domain.Limit;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

public interface PaymentRepository extends JpaRepository<Payment, Long> {

    List<Payment> findByCustomerIdOrderByCreatedAtDesc(Long customerId, Limit limit);

    @Query(value = "SELECT * FROM payments.payments WHERE customer_id = :customerId ORDER BY created_at DESC LIMIT :limit",
           nativeQuery = true)
    List<Payment> historyNative(Long customerId, int limit);
}
