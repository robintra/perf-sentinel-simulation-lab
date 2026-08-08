package com.perfsim.mutinysvc.web;

import static io.restassured.RestAssured.given;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.verifyNoInteractions;

import com.perfsim.mutinysvc.messaging.MessagingFaultService;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import java.util.stream.Stream;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

@QuarkusTest
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class MessagingInvalidContractTest {

    private static final String SUCCESS_MARKER =
            "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0";

    @InjectMock
    MessagingFaultService messagingFaultService;

    private int verifiedResponses;

    @ParameterizedTest
    @MethodSource("invalidPaths")
    void rejectsInvalidMessagingInputBeforePublisherAccess(String path) {
        given().when().post(path).then().statusCode(400);

        verifyNoInteractions(messagingFaultService);
        verifiedResponses++;
    }

    @AfterAll
    void reportsCompleteBoundaryContract() {
        assertEquals(7, verifiedResponses);
        verifyNoInteractions(messagingFaultService);
        System.out.println(SUCCESS_MARKER);
    }

    static Stream<String> invalidPaths() {
        return Stream.of(
                "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
                "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
                "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
                "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported");
    }
}
