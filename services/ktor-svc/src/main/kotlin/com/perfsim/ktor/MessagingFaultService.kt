package com.perfsim.ktor

import com.rabbitmq.client.Channel
import com.rabbitmq.client.Connection
import com.rabbitmq.client.ConnectionFactory
import io.ktor.client.HttpClient
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.opentelemetry.api.GlobalOpenTelemetry
import io.opentelemetry.api.trace.SpanKind
import io.opentelemetry.api.trace.StatusCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.charset.StandardCharsets.UTF_8

private const val CONFIRM_TIMEOUT_MS = 5_000L
private const val NETWORK_MARGIN_MS = 5_000

interface MessagingPublisher {
    suspend fun publishSequentially(messages: Int): Map<String, Any>
    suspend fun publishSlowly(delayMs: Long, repeats: Int): Map<String, Any>
}

class MessagingFaultService(private val httpClient: HttpClient) : MessagingPublisher {
    private val directHost = env("RABBITMQ_HOST", "rabbitmq.messaging.svc.cluster.local")
    private val directPort = envInt("RABBITMQ_PORT", 5_672)
    private val slowHost = env("RABBITMQ_SLOW_HOST", "toxiproxy.messaging.svc.cluster.local")
    private val slowPort = envInt("RABBITMQ_SLOW_PORT", 25_672)
    private val toxiproxyApi = env("TOXIPROXY_API", "http://toxiproxy.messaging.svc.cluster.local:8474")
    private val username = System.getenv("RABBITMQ_USERNAME")
    private val password = System.getenv("RABBITMQ_PASSWORD")
    private val tracer = GlobalOpenTelemetry.getTracer(MessagingFaultService::class.java.name)

    override suspend fun publishSequentially(messages: Int): Map<String, Any> = withContext(Dispatchers.IO) {
        connection(directHost, directPort, 0).use { connection ->
            connection.createChannel().use { channel ->
                declareTopology(channel)
                channel.confirmSelect()
                repeat(messages) { index ->
                    channel.basicPublish(EXCHANGE, ROUTING_KEY, null, "ktor-message-$index".toByteArray(UTF_8))
                }
                awaitConfirms(channel, CONFIRM_TIMEOUT_MS)
            }
        }
        mapOf("published" to messages, "confirmed" to messages)
    }

    override suspend fun publishSlowly(delayMs: Long, repeats: Int): Map<String, Any> = withContext(Dispatchers.IO) {
        updateLatency(delayMs)
        var confirmed = 0
        connection(slowHost, slowPort, delayMs).use { connection ->
            connection.createChannel().use { channel ->
                declareTopology(channel)
                channel.confirmSelect()
                repeat(repeats) { index ->
                    val span = tracer.spanBuilder("$EXCHANGE send")
                        .setSpanKind(SpanKind.PRODUCER)
                        .setAttribute("messaging.system", "rabbitmq")
                        .setAttribute("messaging.destination.name", EXCHANGE)
                        .setAttribute("messaging.operation.type", "send")
                        .startSpan()
                    try {
                        span.makeCurrent().use {
                            channel.basicPublish(
                                EXCHANGE,
                                ROUTING_KEY,
                                null,
                                "slow-ktor-message-$index".toByteArray(UTF_8),
                            )
                            awaitConfirms(channel, delayMs + CONFIRM_TIMEOUT_MS)
                            confirmed++
                        }
                    } catch (error: Exception) {
                        span.recordException(error)
                        span.setStatus(StatusCode.ERROR)
                        throw error
                    } finally {
                        span.end()
                    }
                }
            }
        }
        mapOf("published" to repeats, "confirmed" to confirmed, "delay_ms" to delayMs)
    }

    private fun connection(host: String, port: Int, downstreamDelayMs: Long): Connection {
        return rabbitMqConnectionFactory(
            host,
            port,
            downstreamDelayMs,
            requireCredential("RABBITMQ_USERNAME", username),
            requireCredential("RABBITMQ_PASSWORD", password),
        ).newConnection()
    }

    private suspend fun updateLatency(delayMs: Long) {
        val updatePath = "/proxies/rabbitmq-slow/toxics/latency_downstream"
        val attributes = "{\"attributes\":{\"latency\":$delayMs,\"jitter\":0}}"
        var response = sendToxiproxy(updatePath, attributes)
        if (response == 404) {
            val createBody = "{\"name\":\"latency_downstream\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":$delayMs,\"jitter\":0}}"
            response = sendToxiproxy("/proxies/rabbitmq-slow/toxics", createBody)
            if (response == 409) response = sendToxiproxy(updatePath, attributes)
        }
        check(response in 200..299) { "Toxiproxy returned HTTP $response" }
    }

    private suspend fun sendToxiproxy(path: String, body: String): Int =
        httpClient.post(toxiproxyApi + path) {
            contentType(ContentType.Application.Json)
            setBody(body)
        }.status.value

    private fun awaitConfirms(channel: Channel, timeoutMs: Long) {
        try {
            channel.waitForConfirmsOrDie(timeoutMs)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IllegalStateException("Interrupted while awaiting RabbitMQ confirms", error)
        }
    }

    private fun declareTopology(channel: Channel) {
        channel.exchangeDeclare(EXCHANGE, "direct", true)
        channel.queueDeclare(QUEUE, true, false, false, mapOf("x-message-ttl" to 60_000))
        channel.queueBind(QUEUE, EXCHANGE, ROUTING_KEY)
    }

    private fun requireCredential(name: String, value: String?): String =
        requireNotNull(value?.takeIf(String::isNotBlank)) { "$name is required" }

    private companion object {
        const val EXCHANGE = "perfsim.ktor-svc"
        const val QUEUE = "perfsim.ktor-svc"
        const val ROUTING_KEY = "ktor-svc"
    }
}

internal fun rabbitMqConnectionFactory(
    host: String,
    port: Int,
    downstreamDelayMs: Long,
    username: String,
    password: String,
): ConnectionFactory {
    val responseTimeout = Math.toIntExact(downstreamDelayMs + NETWORK_MARGIN_MS)
    return ConnectionFactory().also { factory ->
        factory.setHost(host)
        factory.setPort(port)
        factory.setUsername(username)
        factory.setPassword(password)
        factory.setConnectionTimeout(CONFIRM_TIMEOUT_MS.toInt())
        factory.setHandshakeTimeout(if (downstreamDelayMs == 0L) CONFIRM_TIMEOUT_MS.toInt() else 2 * responseTimeout + 1)
        factory.setChannelRpcTimeout(responseTimeout)
        factory.setShutdownTimeout(responseTimeout)
    }
}

private fun env(name: String, fallback: String): String =
    System.getenv(name)?.takeIf(String::isNotBlank) ?: fallback

private fun envInt(name: String, fallback: Int): Int =
    System.getenv(name)?.takeIf(String::isNotBlank)?.toInt() ?: fallback
