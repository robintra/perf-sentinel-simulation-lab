package com.perfsim.helidonmpsvc.messaging;

import java.util.Map;

public interface MessagingPublisher {

    Map<String, Object> publishSequentially(int messages);

    Map<String, Object> publishSlowly(long delayMs, int repeats);
}
