package com.perfsim.notification.web;

import com.perfsim.notification.domain.Notification;
import com.perfsim.notification.domain.NotificationRepository;
import jakarta.transaction.Transactional;
import java.util.Map;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class NotificationController {

    private final NotificationRepository notifications;

    public NotificationController(NotificationRepository notifications) {
        this.notifications = notifications;
    }

    @PostMapping("/notify")
    @Transactional
    public ResponseEntity<Map<String, Object>> notify(
            @RequestParam Long paymentId,
            @RequestParam(defaultValue = "1") Long customerId) {
        Notification n =
                new Notification(paymentId, customerId, "payment confirmed for #" + paymentId);
        notifications.save(n);
        return ResponseEntity.ok(Map.<String, Object>of(
                "notificationId", n.getId(),
                "paymentId", paymentId,
                "channel", n.getChannel()));
    }

    @GetMapping("/external/mock")
    public ResponseEntity<Map<String, Object>> externalMock(
            @RequestParam(defaultValue = "0") long delayMs) {
        if (delayMs > 0) {
            try {
                Thread.sleep(delayMs);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return ResponseEntity.ok(Map.<String, Object>of(
                "ok", true, "delayed_ms", delayMs, "now", System.currentTimeMillis()));
    }
}
