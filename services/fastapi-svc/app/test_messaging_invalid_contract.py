import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
from aio_pika.robust_connection import RobustConnection

from app import main, messaging


class MessagingInvalidContract(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.publisher = SimpleNamespace(
            publish_sequentially=AsyncMock(
                side_effect=AssertionError("invalid request reached RabbitMQ")
            ),
            publish_slowly=AsyncMock(
                side_effect=AssertionError(
                    "invalid request reached RabbitMQ or Toxiproxy"
                )
            ),
        )
        dependency = getattr(main, "get_messaging_publisher", None)
        if dependency is not None:
            main.app.dependency_overrides[dependency] = lambda: self.publisher
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=main.app),
            base_url="http://test",
        )

    async def asyncTearDown(self):
        await self.client.aclose()
        main.app.dependency_overrides.clear()

    async def test_invalid_requests_do_not_reach_messaging(self):
        invalid = [
            "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
        ]

        statuses = [(await self.client.post(path)).status_code for path in invalid]

        self.assertEqual(statuses, [400] * 7)
        self.assertEqual(self.publisher.publish_sequentially.await_count, 0)
        self.assertEqual(self.publisher.publish_slowly.await_count, 0)
        print(
            "\nPERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0",
            flush=True,
        )


class MessagingConnectionContract(unittest.IsolatedAsyncioTestCase):
    async def test_connect_keeps_aio_pika_default_fail_fast(self):
        connect = AsyncMock(return_value=object())

        with patch.object(messaging.aio_pika, "connect_robust", connect):
            await messaging._connect(
                "RABBITMQ_HOST",
                "RABBITMQ_PORT",
                "rabbitmq",
                5672,
                "guest",
                "guest",
            )

        self.assertNotIn("fail_fast", connect.await_args.kwargs)
        fail_fast = next(
            parameter
            for parameter in RobustConnection.PARAMETERS
            if parameter.name == "fail_fast"
        )
        self.assertEqual(fail_fast.default, "1")


if __name__ == "__main__":
    unittest.main()
