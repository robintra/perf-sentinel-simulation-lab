import os
import unittest
from unittest.mock import patch

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "djangosvc.settings")

import django
from django.test import Client

django.setup()


class MessagingInvalidContract(unittest.TestCase):
    def test_pika_ack_without_return_value_counts_as_confirmed(self):
        class Channel:
            is_open = True

            def exchange_declare(self, *_args, **_kwargs):
                pass

            def queue_declare(self, *_args, **_kwargs):
                pass

            def queue_bind(self, *_args, **_kwargs):
                pass

            def confirm_delivery(self):
                pass

            def basic_publish(self, *_args, **_kwargs):
                return None

            def close(self):
                self.is_open = False

        class Connection:
            is_open = True

            def __init__(self):
                self.channel_instance = Channel()

            def channel(self):
                return self.channel_instance

            def close(self):
                self.is_open = False

        from djangosvc import messaging

        with patch.object(messaging, "_connection", return_value=Connection()):
            confirmed = messaging._publish_many(
                "RABBITMQ_HOST",
                "RABBITMQ_PORT",
                "rabbitmq",
                5672,
                2,
                "test-message",
                5,
            )

        self.assertEqual(confirmed, 2)

    def test_invalid_requests_do_not_reach_messaging(self):
        calls = {"sequential": 0, "slow": 0}

        def publish_sequentially(_messages):
            calls["sequential"] += 1
            self.fail("invalid request reached RabbitMQ")

        def publish_slowly(_delay_ms, _repeats):
            calls["slow"] += 1
            self.fail("invalid request reached RabbitMQ or Toxiproxy")

        from djangosvc import messaging

        invalid = [
            "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
        ]

        with (
            patch.object(messaging, "publish_sequentially", publish_sequentially),
            patch.object(messaging, "publish_slowly", publish_slowly),
        ):
            client = Client()
            for path in invalid:
                self.assertEqual(client.post(path).status_code, 400, path)

        self.assertEqual(calls, {"sequential": 0, "slow": 0})
        print(
            "\nPERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0",
            flush=True,
        )
