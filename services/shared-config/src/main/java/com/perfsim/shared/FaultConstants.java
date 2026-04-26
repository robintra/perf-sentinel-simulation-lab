package com.perfsim.shared;

public final class FaultConstants {

    public static final int DEFAULT_ITEMS = 15;
    public static final int DEFAULT_REPEATS = 10;
    public static final long DEFAULT_DELAY_MS = 600L;
    public static final int DEFAULT_FANOUT_WIDTH = 40;
    public static final int DEFAULT_CHATTY_CALLS = 30;
    public static final int DEFAULT_POOL_CONCURRENCY = 20;
    public static final int DEFAULT_SERIALIZED_STEPS = 6;

    public static final String EXTERNAL_MOCK_BASE = "http://notification-service.shop.svc.cluster.local:8082/api/external/mock";
    public static final String ORDER_BASE = "http://order-service.shop.svc.cluster.local:8080";
    public static final String PAYMENT_BASE = "http://payment-service.shop.svc.cluster.local:8081";
    public static final String NOTIFICATION_BASE = "http://notification-service.shop.svc.cluster.local:8082";

    private FaultConstants() {}
}
