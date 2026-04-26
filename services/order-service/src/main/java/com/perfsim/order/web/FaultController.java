package com.perfsim.order.web;

import com.perfsim.order.domain.Order;
import com.perfsim.order.domain.OrderRepository;
import com.perfsim.shared.BaseFaultController;
import com.perfsim.shared.FaultConstants;
import com.perfsim.shared.FaultResponse;
import jakarta.transaction.Transactional;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
@RequestMapping("/api/fault")
public class FaultController extends BaseFaultController {

    private final OrderRepository orders;
    private final RestClient paymentClient;

    public FaultController(OrderRepository orders, RestClient paymentClient) {
        this.orders = orders;
        this.paymentClient = paymentClient;
    }

    @Override
    protected String serviceName() {
        return "order-service";
    }

    @PostMapping("/n-plus-one-sql")
    @Transactional
    public ResponseEntity<FaultResponse> nPlusOneSql(
            @RequestParam(defaultValue = "15") int items) {
        return runFault(
                "n_plus_one_sql",
                Map.of("items", items),
                () -> {
                    List<Order> first = orders.findFirst50ByStatus("PENDING");
                    int touched = 0;
                    int total = 0;
                    for (Order o : first) {
                        if (touched >= items) {
                            break;
                        }
                        // Lazy-loaded items collection: each access fires a separate SQL
                        // SELECT * FROM order_items WHERE order_id = ? — that is the N+1.
                        total += o.getItems().size();
                        touched++;
                    }
                    return Map.of("orders_touched", touched, "items_total", total);
                });
    }

    @PostMapping("/redundant-http")
    public ResponseEntity<FaultResponse> redundantHttp(
            @RequestParam(defaultValue = "10") int repeats) {
        return runFault(
                "redundant_http",
                Map.of("repeats", repeats),
                () -> {
                    int ok = 0;
                    for (int i = 0; i < repeats; i++) {
                        // Same call, same params, same response. Detector flags this
                        // as redundant_http when count >= n_plus_one_min_occurrences.
                        Map<?, ?> resp = paymentClient
                                .get()
                                .uri("/api/payments/history?customerId=1&limit=10")
                                .retrieve()
                                .body(Map.class);
                        if (resp != null) {
                            ok++;
                        }
                    }
                    return Map.of("calls_made", repeats, "calls_ok", ok);
                });
    }

    @PostMapping("/slow-sql")
    public ResponseEntity<FaultResponse> slowSql(
            @RequestParam(defaultValue = "600") long delayMs,
            @RequestParam(defaultValue = "6") int repeats) {
        return runFault(
                "slow_sql",
                Map.of("delayMs", delayMs, "repeats", repeats),
                () -> {
                    double seconds = delayMs / 1000.0;
                    int executed = 0;
                    for (int i = 0; i < repeats; i++) {
                        orders.slowQuery(seconds);
                        executed++;
                    }
                    return Map.of("queries_executed", executed, "delay_ms", delayMs);
                });
    }

    @PostMapping("/pool-saturation")
    public ResponseEntity<FaultResponse> poolSaturation(
            @RequestParam(defaultValue = "20") int concurrency) {
        return runFault(
                "pool_saturation",
                Map.of("concurrency", concurrency),
                () -> {
                    ExecutorService pool = Executors.newFixedThreadPool(concurrency);
                    try {
                        List<CompletableFuture<Long>> futures = new java.util.ArrayList<>();
                        for (int i = 0; i < concurrency; i++) {
                            futures.add(CompletableFuture.supplyAsync(
                                    () -> {
                                        // Each task holds a Hikari connection for ~400 ms.
                                        // With concurrency > pool size (10), the queue piles up
                                        // and the saturation detector kicks in.
                                        orders.slowQuery(0.4);
                                        return 1L;
                                    },
                                    pool));
                        }
                        long completed = futures.stream()
                                .map(CompletableFuture::join)
                                .mapToLong(Long::longValue)
                                .sum();
                        return Map.of("tasks_launched", concurrency, "tasks_completed", completed);
                    } finally {
                        pool.shutdown();
                    }
                });
    }

    @PostMapping("/seed")
    @Transactional
    public ResponseEntity<FaultResponse> seed(@RequestParam(defaultValue = "50") int extra) {
        return runFault(
                "seed",
                Map.of("extra", extra),
                () -> Map.of("base_url", FaultConstants.ORDER_BASE, "extra_requested", extra));
    }
}
