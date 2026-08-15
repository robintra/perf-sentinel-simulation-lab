<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\Common;
use App\Models\Payment;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class BusinessController extends Controller
{
    use Common;

    // GET /api/external/mock: the inert target the HTTP faults call back into.
    public function mock(Request $r)
    {
        $delay = $this->intParam($r, 'delayMs', 0);
        if ($delay > 0) {
            usleep($delay * 1000);
        }
        return response()->json([
            'ok' => true,
            'seq' => $this->intParam($r, 'seq', 0),
            'op' => $this->intParam($r, 'op', 0),
            'delayMs' => $delay,
        ]);
    }

    // GET /api/dispatch/{channel}
    public function dispatch(Request $r, string $channel)
    {
        if (! in_array($channel, self::CHANNELS, true)) {
            return response()->json(['error' => 'unknown channel'], 404);
        }
        $delay = $this->intParam($r, 'delayMs', 0);
        if ($delay > 0) {
            usleep($delay * 1000);
        }
        return response()->json(['channel' => $channel, 'dispatched' => true, 'delayMs' => $delay]);
    }

    // GET /api/payments/history: a real Eloquent read (php.laravel + php.pdo).
    // ?hold=1 briefly holds the connection (pg_sleep) so the pool-saturation
    // fan-out produces genuinely overlapping DB spans across workers.
    public function paymentsHistory(Request $r)
    {
        $customerId = $this->intParam($r, 'customerId', 1);
        $limit = max(1, min($this->intParam($r, 'limit', 10), 100));
        if ($this->intParam($r, 'hold', 0) > 0) {
            DB::select('SELECT pg_sleep(?)', [0.3]);
        }
        $rows = Payment::where('customer_id', $customerId)
            ->orderBy('id')
            ->limit($limit)
            ->get(['id', 'order_id', 'customer_id', 'amount_cents', 'status']);
        return response()->json($rows);
    }
}
