import os

import pika
import requests
from opentelemetry import trace
from opentelemetry.trace import SpanKind

DESTINATION = "perfsim.django-svc"
ROUTING_KEY = "django-svc"
CONFIRM_TIMEOUT_SECONDS = 5
_tracer = trace.get_tracer(__name__)


def _required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def _connection(host_name, port_name, default_host, default_port, timeout):
    return pika.BlockingConnection(pika.ConnectionParameters(
        host=os.environ.get(host_name, default_host),
        port=int(os.environ.get(port_name, str(default_port))),
        credentials=pika.PlainCredentials(
            _required("RABBITMQ_USERNAME"),
            _required("RABBITMQ_PASSWORD"),
        ),
        connection_attempts=1,
        socket_timeout=timeout,
        stack_timeout=timeout + 1,
        blocked_connection_timeout=timeout,
    ))


def _publish_many(host_name, port_name, default_host, default_port, count, prefix, timeout):
    connection = _connection(host_name, port_name, default_host, default_port, timeout)
    confirmed = 0
    channel = None
    try:
        channel = connection.channel()
        try:
            channel.exchange_declare(DESTINATION, exchange_type="direct", durable=True)
            channel.queue_declare(
                DESTINATION,
                durable=True,
                arguments={"x-message-ttl": 60_000},
            )
            channel.queue_bind(DESTINATION, DESTINATION, ROUTING_KEY)
            channel.confirm_delivery()
            for index in range(count):
                with _tracer.start_as_current_span(
                    f"{DESTINATION} send",
                    kind=SpanKind.PRODUCER,
                    attributes={
                        "messaging.system": "rabbitmq",
                        "messaging.destination.name": DESTINATION,
                        "messaging.operation.type": "send",
                    },
                ):
                    channel.basic_publish(
                        DESTINATION,
                        ROUTING_KEY,
                        f"{prefix}-{index}".encode(),
                        properties=pika.BasicProperties(delivery_mode=2),
                        mandatory=True,
                    )
                    confirmed += 1
        finally:
            if channel is not None and channel.is_open:
                channel.close()
    finally:
        if connection.is_open:
            connection.close()
    return confirmed


def _update_latency(delay_ms):
    api = os.environ.get(
        "TOXIPROXY_API",
        "http://toxiproxy.messaging.svc.cluster.local:8474",
    )
    update_url = f"{api}/proxies/rabbitmq-slow/toxics/latency_downstream"
    attributes = {"attributes": {"latency": delay_ms, "jitter": 0}}
    response = requests.post(update_url, json=attributes, timeout=5)
    if response.status_code == 404:
        response = requests.post(
            f"{api}/proxies/rabbitmq-slow/toxics",
            json={
                "name": "latency_downstream",
                "type": "latency",
                "stream": "downstream",
                "attributes": {"latency": delay_ms, "jitter": 0},
            },
            timeout=5,
        )
        if response.status_code == 409:
            response = requests.post(update_url, json=attributes, timeout=5)
    response.raise_for_status()


def publish_sequentially(messages):
    confirmed = _publish_many(
        "RABBITMQ_HOST",
        "RABBITMQ_PORT",
        "rabbitmq.messaging.svc.cluster.local",
        5672,
        messages,
        "django-message",
        CONFIRM_TIMEOUT_SECONDS,
    )
    return {"published": messages, "confirmed": confirmed}


def publish_slowly(delay_ms, repeats):
    _update_latency(delay_ms)
    confirmed = _publish_many(
        "RABBITMQ_SLOW_HOST",
        "RABBITMQ_SLOW_PORT",
        "toxiproxy.messaging.svc.cluster.local",
        25672,
        repeats,
        "slow-django-message",
        delay_ms / 1000 + CONFIRM_TIMEOUT_SECONDS,
    )
    return {"published": repeats, "confirmed": confirmed, "delay_ms": delay_ms}
