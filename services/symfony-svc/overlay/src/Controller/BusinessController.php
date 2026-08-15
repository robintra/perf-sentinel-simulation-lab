<?php

namespace App\Controller;

use App\Entity\Payment;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\Routing\Attribute\Route;

class BusinessController extends AbstractController
{
    use Common;

    public function __construct(private EntityManagerInterface $em)
    {
    }

    // GET /api/external/mock: the inert target the HTTP faults call back into.
    #[Route('/api/external/mock', methods: ['GET'])]
    public function mock(Request $r): JsonResponse
    {
        $delay = $this->intParam($r, 'delayMs', 0);
        if ($delay > 0) {
            usleep($delay * 1000);
        }
        return new JsonResponse([
            'ok' => true,
            'seq' => $this->intParam($r, 'seq', 0),
            'op' => $this->intParam($r, 'op', 0),
            'delayMs' => $delay,
        ]);
    }

    // GET /api/dispatch/{channel}
    #[Route('/api/dispatch/{channel}', methods: ['GET'])]
    public function dispatch(Request $r, string $channel): JsonResponse
    {
        if (! in_array($channel, self::CHANNELS, true)) {
            return new JsonResponse(['error' => 'unknown channel'], 404);
        }
        $delay = $this->intParam($r, 'delayMs', 0);
        if ($delay > 0) {
            usleep($delay * 1000);
        }
        return new JsonResponse(['channel' => $channel, 'dispatched' => true, 'delayMs' => $delay]);
    }

    // GET /api/payments/history: a real Doctrine read (php.doctrine + php.pdo).
    // ?hold=1 briefly holds the connection so the pool-saturation fan-out produces
    // genuinely overlapping DB spans across workers.
    #[Route('/api/payments/history', methods: ['GET'])]
    public function paymentsHistory(Request $r): JsonResponse
    {
        $customerId = $this->intParam($r, 'customerId', 1);
        $limit = max(1, min($this->intParam($r, 'limit', 10), 100));
        if ($this->intParam($r, 'hold', 0) > 0) {
            $this->em->getConnection()->executeQuery('SELECT pg_sleep(?)', [0.3]);
        }
        $rows = $this->em->getRepository(Payment::class)
            ->findBy(['customerId' => $customerId], ['id' => 'ASC'], $limit);
        $out = array_map(static fn (Payment $p) => [
            'id' => $p->id,
            'order_id' => $p->orderId,
            'customer_id' => $p->customerId,
            'amount_cents' => $p->amountCents,
            'status' => $p->status,
        ], $rows);
        return new JsonResponse($out);
    }
}
