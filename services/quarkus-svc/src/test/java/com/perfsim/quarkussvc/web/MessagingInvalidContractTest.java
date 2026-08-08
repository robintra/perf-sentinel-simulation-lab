package com.perfsim.quarkussvc.web;

import static io.restassured.RestAssured.given;
import static org.mockito.Mockito.verifyNoInteractions;

import com.perfsim.quarkussvc.messaging.MessagingFaultService;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import java.util.stream.Stream;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

@QuarkusTest
class MessagingInvalidContractTest {

    @InjectMock
    MessagingFaultService messagingFaultService;

    @ParameterizedTest
    @MethodSource("invalidPaths")
    void rejectsInvalidMessagingInputBeforePublisherAccess(String path) {
        given().when().post(path).then().statusCode(400);

        verifyNoInteractions(messagingFaultService);
    }

    static Stream<String> invalidPaths() {
        return Stream.of(
                "/api/fault/n-plus-one-messaging?messages=4",
                "/api/fault/n-plus-one-messaging?messages=101",
                "/api/fault/slow-messaging?delayMs=500&repeats=3",
                "/api/fault/slow-messaging?delayMs=5001&repeats=3",
                "/api/fault/slow-messaging?delayMs=600&repeats=2",
                "/api/fault/slow-messaging?delayMs=600&repeats=21",
                "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported");
    }
}
