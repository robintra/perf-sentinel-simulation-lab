// Shared helpers for k6 scenarios. Each scenario imports the URLs and
// the antiPattern tag and runs against the in-cluster services.

export const ORDER_SVC_URL =
    __ENV.ORDER_SVC_URL || 'http://order-service.shop.svc.cluster.local:8080';
export const PAYMENT_SVC_URL =
    __ENV.PAYMENT_SVC_URL || 'http://payment-service.shop.svc.cluster.local:8081';
export const NOTIFICATION_SVC_URL =
    __ENV.NOTIFICATION_SVC_URL || 'http://notification-service.shop.svc.cluster.local:8082';

export const COMMON_HEADERS = {
    'Content-Type': 'application/json',
};

// Default scenario shape: 5 VUs for 30s. Each scenario can override.
export const DEFAULT_OPTIONS = {
    vus: 5,
    duration: '30s',
    thresholds: {
        http_req_failed: ['rate<0.05'],
    },
};
