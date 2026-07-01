<?php

namespace App\Controller;

use App\Entity\OrderItem;
use App\Entity\Payment;
use App\Support\Http;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\Routing\Attribute\Route;

class FaultController extends AbstractController
{
    use Common;

    public function __construct(private EntityManagerInterface $em)
    {
    }

    // === SQL faults (through Doctrine -> php.doctrine + php.pdo scopes) ========

    // N distinct Doctrine record loads, one per order id. Same obfuscated template
    // across the loop -> sanitized -> redundant_sql under `auto`, n_plus_one_sql
    // under `strict` + >=15 occurrences. Either way framework == php_doctrine
    // (the DBAL span rides io.opentelemetry.contrib.php.doctrine).
    #[Route('/api/fault/n-plus-one-sql', methods: ['POST'])]
    public function nPlusOneSql(Request $r): JsonResponse
    {
        $items = $this->intParam($r, 'items', 20);
        $start = hrtime(true);
        $total = 0;
        $repo = $this->em->getRepository(OrderItem::class);
        for ($id = 1; $id <= $items; $id++) {
            $total += count($repo->findBy(['orderId' => $id]));
        }
        return $this->envelope('n_plus_one_sql', $start, [
            'items' => $items, 'orders_touched' => $items, 'items_total' => $total,
        ]);
    }

    #[Route('/api/fault/redundant-sql', methods: ['POST'])]
    public function redundantSql(Request $r): JsonResponse
    {
        $repeats = $this->intParam($r, 'repeats', 10);
        $start = hrtime(true);
        $total = 0;
        $repo = $this->em->getRepository(Payment::class);
        for ($i = 0; $i < $repeats; $i++) {
            $total += count($repo->findBy(['customerId' => 1]));
        }
        return $this->envelope('redundant_sql', $start, [
            'repeats' => $repeats, 'queries_made' => $repeats, 'rows_seen' => $total,
        ]);
    }

    #[Route('/api/fault/slow-sql', methods: ['POST'])]
    public function slowSql(Request $r): JsonResponse
    {
        $delayMs = $this->intParam($r, 'delayMs', 600);
        $repeats = $this->intParam($r, 'repeats', 6);
        $seconds = $delayMs / 1000.0;
        $start = hrtime(true);
        $executed = 0;
        $conn = $this->em->getConnection();
        for ($i = 0; $i < $repeats; $i++) {
            $conn->executeQuery('SELECT pg_sleep(?), orders.id FROM orders ORDER BY id OFFSET ? LIMIT 1', [$seconds, $i]);
            $executed++;
        }
        return $this->envelope('slow_sql', $start, [
            'delayMs' => $delayMs, 'repeats' => $repeats, 'queries_executed' => $executed,
        ]);
    }

    // Concurrent self-calls that each HOLD a Doctrine connection -> overlapping DB
    // spans -> pool_saturation (structural; no framework tag).
    #[Route('/api/fault/pool-saturation', methods: ['POST'])]
    public function poolSaturation(Request $r): JsonResponse
    {
        $concurrency = $this->intParam($r, 'concurrency', 20);
        $start = hrtime(true);
        $urls = [];
        for ($i = 0; $i < $concurrency; $i++) {
            $urls[] = $this->selfBase().'/api/payments/history?customerId=1&limit=5&hold=1';
        }
        $completed = Http::getMany($urls);
        return $this->envelope('pool_saturation', $start, [
            'concurrency' => $concurrency, 'tasks_launched' => $concurrency, 'tasks_completed' => $completed,
        ]);
    }

    // === HTTP faults (own CLIENT spans; no doctrine scope -> php_generic) =======

    #[Route('/api/fault/n-plus-one-http', methods: ['POST'])]
    public function nPlusOneHttp(Request $r): JsonResponse
    {
        $recipients = $this->intParam($r, 'recipients', 10);
        $start = hrtime(true);
        $ok = 0;
        for ($i = 0; $i < $recipients; $i++) {
            $ok += Http::get($this->selfBase()."/api/external/mock?delayMs=0&seq={$i}&op=0");
        }
        return $this->envelope('n_plus_one_http', $start, [
            'recipients' => $recipients, 'calls_made' => $recipients, 'calls_ok' => $ok,
        ]);
    }

    #[Route('/api/fault/redundant-http', methods: ['POST'])]
    public function redundantHttp(Request $r): JsonResponse
    {
        $repeats = $this->intParam($r, 'repeats', 10);
        $start = hrtime(true);
        $ok = 0;
        for ($i = 0; $i < $repeats; $i++) {
            $ok += Http::get($this->selfBase().'/api/payments/history?customerId=1&limit=10');
        }
        return $this->envelope('redundant_http', $start, [
            'repeats' => $repeats, 'calls_made' => $repeats, 'calls_ok' => $ok,
        ]);
    }

    #[Route('/api/fault/slow-http', methods: ['POST'])]
    public function slowHttp(Request $r): JsonResponse
    {
        $delayMs = $this->intParam($r, 'delayMs', 600);
        $repeats = $this->intParam($r, 'repeats', 6);
        $start = hrtime(true);
        $ok = 0;
        for ($i = 0; $i < $repeats; $i++) {
            $ok += Http::get($this->selfBase()."/api/external/mock?delayMs={$delayMs}&seq={$i}&op=0");
        }
        return $this->envelope('slow_http', $start, [
            'delayMs' => $delayMs, 'repeats' => $repeats, 'calls_made' => $repeats, 'calls_ok' => $ok,
        ]);
    }

    #[Route('/api/fault/fanout', methods: ['POST'])]
    public function fanout(Request $r): JsonResponse
    {
        $width = $this->intParam($r, 'width', 40);
        $start = hrtime(true);
        $urls = [];
        for ($i = 0; $i < $width; $i++) {
            $urls[] = $this->selfBase()."/api/external/mock?delayMs=10&seq={$i}&op=0";
        }
        $ok = Http::getMany($urls);
        return $this->envelope('excessive_fanout', $start, [
            'width' => $width, 'children_launched' => $width, 'children_ok' => $ok,
        ]);
    }

    #[Route('/api/fault/chatty', methods: ['POST'])]
    public function chatty(Request $r): JsonResponse
    {
        $calls = $this->intParam($r, 'calls', 30);
        $start = hrtime(true);
        $ok = 0;
        for ($i = 0; $i < $calls; $i++) {
            $ok += Http::get($this->selfBase()."/api/external/mock?delayMs=5&seq={$i}&op=".($i % 7));
        }
        return $this->envelope('chatty_service', $start, [
            'calls' => $calls, 'calls_made' => $calls, 'calls_ok' => $ok,
        ]);
    }

    #[Route('/api/fault/serialized', methods: ['POST'])]
    public function serialized(Request $r): JsonResponse
    {
        $steps = min($this->intParam($r, 'steps', 6), count(self::CHANNELS));
        $start = hrtime(true);
        $ok = 0;
        for ($i = 0; $i < $steps; $i++) {
            $ok += Http::get($this->selfBase().'/api/dispatch/'.self::CHANNELS[$i].'?delayMs=80');
        }
        return $this->envelope('serialized_calls', $start, [
            'steps' => $steps, 'steps_ok' => $ok,
        ]);
    }
}
