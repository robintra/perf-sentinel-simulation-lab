import asyncio
import os

import aio_pika
import httpx
from opentelemetry import trace
from opentelemetry.trace import SpanKind, StatusCode
from pamqp.commands import Basic

DESTINATION = "perfsim.fastapi-svc"
ROUTING_KEY = "fastapi-svc"
CONFIRM_TIMEOUT_SECONDS = 5
_tracer = trace.get_tracer(__name__)


def _required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def _credentials():
    return _required("RABBITMQ_USERNAME"), _required("RABBITMQ_PASSWORD")


async def _connect(host_name, port_name, default_host, default_port, username, password):
    return await aio_pika.connect_robust(
        host=os.environ.get(host_name, default_host),
        port=int(os.environ.get(port_name, str(default_port))),
        login=username,
        password=password,
        timeout=CONFIRM_TIMEOUT_SECONDS,
    )


async def _publish_confirmed(exchange, payload, timeout):
    span = _tracer.start_span(
        f"{DESTINATION} send",
        kind=SpanKind.PRODUCER,
        attributes={
            "messaging.system": "rabbitmq",
            "messaging.destination.name": DESTINATION,
            "messaging.operation.type": "send",
        },
    )
    try:
        with trace.use_span(
            span,
            end_on_exit=False,
            record_exception=False,
            set_status_on_exception=False,
        ):
            confirmation = await exchange.publish(
                aio_pika.Message(
                    payload.encode(),
                    delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
                ),
                routing_key=ROUTING_KEY,
                mandatory=True,
                timeout=timeout,
            )
        if not isinstance(confirmation, Basic.Ack):
            raise RuntimeError(f"RabbitMQ publication was not acknowledged: {confirmation!r}")
    except Exception as error:
        span.record_exception(error)
        span.set_status(StatusCode.ERROR)
        raise
    finally:
        span.end()


async def _publish_many(
    host_name,
    port_name,
    default_host,
    default_port,
    count,
    prefix,
    timeout,
    username,
    password,
):
    connection = await _connect(
        host_name,
        port_name,
        default_host,
        default_port,
        username,
        password,
    )
    async with connection:
        async with connection.channel(
            publisher_confirms=True,
            on_return_raises=True,
        ) as channel:
            exchange = await channel.declare_exchange(
                DESTINATION,
                aio_pika.ExchangeType.DIRECT,
                durable=True,
                timeout=timeout,
            )
            queue = await channel.declare_queue(
                DESTINATION,
                durable=True,
                arguments={"x-message-ttl": 60_000},
                timeout=timeout,
            )
            await queue.bind(exchange, routing_key=ROUTING_KEY, timeout=timeout)
            for index in range(count):
                await _publish_confirmed(exchange, f"{prefix}-{index}", timeout)
    return count


async def _update_latency(delay_ms):
    api = os.environ.get(
        "TOXIPROXY_API",
        "http://toxiproxy.messaging.svc.cluster.local:8474",
    ).rstrip("/")
    update_url = f"{api}/proxies/rabbitmq-slow/toxics/latency_downstream"
    attributes = {"attributes": {"latency": delay_ms, "jitter": 0}}
    async with asyncio.timeout(CONFIRM_TIMEOUT_SECONDS):
        async with httpx.AsyncClient(timeout=CONFIRM_TIMEOUT_SECONDS) as client:
            response = await client.post(update_url, json=attributes)
            if response.status_code == 404:
                response = await client.post(
                    f"{api}/proxies/rabbitmq-slow/toxics",
                    json={
                        "name": "latency_downstream",
                        "type": "latency",
                        "stream": "downstream",
                        "attributes": {"latency": delay_ms, "jitter": 0},
                    },
                )
                if response.status_code == 409:
                    response = await client.post(update_url, json=attributes)
            response.raise_for_status()


async def publish_sequentially(messages):
    username, password = _credentials()
    confirmed = await _publish_many(
        "RABBITMQ_HOST",
        "RABBITMQ_PORT",
        "rabbitmq.messaging.svc.cluster.local",
        5672,
        messages,
        "fastapi-message",
        CONFIRM_TIMEOUT_SECONDS,
        username,
        password,
    )
    return {"published": messages, "confirmed": confirmed}


async def publish_slowly(delay_ms, repeats):
    username, password = _credentials()
    await _update_latency(delay_ms)
    confirmed = await _publish_many(
        "RABBITMQ_SLOW_HOST",
        "RABBITMQ_SLOW_PORT",
        "toxiproxy.messaging.svc.cluster.local",
        25672,
        repeats,
        "slow-fastapi-message",
        delay_ms / 1000 + CONFIRM_TIMEOUT_SECONDS,
        username,
        password,
    )
    return {"published": repeats, "confirmed": confirmed, "delay_ms": delay_ms}
