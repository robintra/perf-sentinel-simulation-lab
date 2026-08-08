package com.perfsim.ktor

import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.testApplication
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class ApplicationTest {
    @Test
    fun exposesAllSeventeenRoutes() = testApplication {
        application { module(testing = true, messagingPublisher = RecordingPublisher()) }

        val posts = listOf(
            "/api/fault/n-plus-one-sql",
            "/api/fault/n-plus-one-http",
            "/api/fault/redundant-sql",
            "/api/fault/redundant-http",
            "/api/fault/slow-sql",
            "/api/fault/slow-http",
            "/api/fault/fanout",
            "/api/fault/chatty",
            "/api/fault/serialized",
            "/api/fault/pool-saturation",
            "/api/fault/n-plus-one-messaging",
            "/api/fault/slow-messaging",
        )
        val gets = listOf(
            "/api/external/mock",
            "/api/dispatch/email",
            "/api/payments/history",
            "/health/live",
            "/health/ready",
        )

        posts.forEach { path -> assertNotEquals(HttpStatusCode.NotFound, client.post(path).status, path) }
        gets.forEach { path -> assertNotEquals(HttpStatusCode.NotFound, client.get(path).status, path) }
        assertEquals(17, posts.size + gets.size)
    }

    @Test
    fun messagingRoutesDefaultToRabbitMqParameters() = testApplication {
        val publisher = RecordingPublisher()
        application { module(testing = true, messagingPublisher = publisher) }

        val direct = client.post("/api/fault/n-plus-one-messaging")
        val slow = client.post("/api/fault/slow-messaging")

        assertEquals(HttpStatusCode.OK, direct.status)
        assertEquals(HttpStatusCode.OK, slow.status)
        assertEquals(8, publisher.lastMessages)
        assertEquals(600L to 3, publisher.lastSlow)
        assertTrue(direct.bodyAsText().contains("\"broker\":\"rabbitmq\""))
        assertTrue(slow.bodyAsText().contains("\"broker\":\"rabbitmq\""))
    }

    @Test
    fun rabbitMqFactoryUsesSuppliedCredentials() {
        val factory = rabbitMqConnectionFactory(
            host = "rabbitmq.example",
            port = 5_672,
            downstreamDelayMs = 0,
            username = "service-user",
            password = "service-password",
        )

        assertEquals("rabbitmq.example", factory.host)
        assertEquals(5_672, factory.port)
        assertEquals("service-user", factory.username)
        assertEquals("service-password", factory.password)
    }

    @Test
    fun messagingInvalidContract() = testApplication {
        val publisher = RecordingPublisher()
        application { module(testing = true, messagingPublisher = publisher) }

        val invalid = listOf(
            "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
        )
        invalid.forEach { path -> assertEquals(HttpStatusCode.BadRequest, client.post(path).status, path) }
        assertEquals(0, publisher.publishSequentiallyCalls)
        assertEquals(0, publisher.publishSlowlyCalls)
        println("PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0")
    }
}

private class RecordingPublisher : MessagingPublisher {
    var publishSequentiallyCalls = 0
    var publishSlowlyCalls = 0
    var lastMessages: Int? = null
    var lastSlow: Pair<Long, Int>? = null

    override suspend fun publishSequentially(messages: Int): Map<String, Any> {
        publishSequentiallyCalls++
        lastMessages = messages
        return mapOf("published" to messages, "confirmed" to messages)
    }

    override suspend fun publishSlowly(delayMs: Long, repeats: Int): Map<String, Any> {
        publishSlowlyCalls++
        lastSlow = delayMs to repeats
        return mapOf("published" to repeats, "confirmed" to repeats, "delay_ms" to delayMs)
    }
}
