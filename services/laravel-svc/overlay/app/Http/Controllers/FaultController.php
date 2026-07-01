<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Concerns\Common;
use App\Models\OrderItem;
use App\Models\Payment;
use App\Support\Http;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class FaultController extends Controller
{
    use Common;

    // === SQL faults (through Eloquent -> php.laravel + php.pdo scopes) ========

    // N distinct Eloquent record loads, one per order id. The obfuscated PDO
    // template is identical across the loop (params are bound, not inlined), so
    // under the daemon's `auto` classification this can surface as redundant_sql;
    // under `strict` + >=15 occurrences it is reclassified to n_plus_one_sql.
    // Either way suggested_fix.framework == php_laravel_eloquent. Default 20
    // (>= 3 * n_plus_one_threshold) to pin the strict-mode reclassification.
    public function nPlusOneSql(Request $r)
    {
        $items = $this->intParam($r, 'items', 20);
        $start = hrtime(true);
        $total = 0;
        for ($id = 1; $id <= $items; $id++) {
            $total += OrderItem::where('order_id', $id)->get()->count();
        }
        return $this->envelope('n_plus_one_sql', $start, [
            'items' => $items, 'orders_touched' => $items, 'items_total' => $total,
        ]);
    }

    // The same Eloquent load repeated with identical params -> redundant_sql.
    public function redundantSql(Request $r)
    {
        $repeats = $this->intParam($r, 'repeats', 10);
        $start = hrtime(true);
        $total = 0;
        for ($i = 0; $i < $repeats; $i++) {
            $total += Payment::where('customer_id', 1)->get()->count();
        }
        return $this->envelope('redundant_sql', $start, [
            'repeats' => $repeats, 'queries_made' => $repeats, 'rows_seen' => $total,
        ]);
    }

    // A leading pg_sleep makes each query slow -> slow_sql.
    public function slowSql(Request $r)
    {
        $delayMs = $this->intParam($r, 'delayMs', 600);
        $repeats = $this->intParam($r, 'repeats', 6);
        $seconds = $delayMs / 1000.0;
        $start = hrtime(true);
        $executed = 0;
        for ($i = 0; $i < $repeats; $i++) {
            DB::select('SELECT pg_sleep(?), orders.id FROM orders ORDER BY id OFFSET ? LIMIT 1', [$seconds, $i]);
            $executed++;
        }
        return $this->envelope('slow_sql', $start, [
            'delayMs' => $delayMs, 'repeats' => $repeats, 'queries_executed' => $executed,
        ]);
    }

    // Concurrent self-calls that each HOLD a DB connection (?hold=1 -> pg_sleep)
    // -> overlapping SQL spans across distinct workers -> pool_saturation. curl_multi
    // is PHP's native concurrency (no userland threads).
    public function poolSaturation(Request $r)
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

    // === HTTP faults (own CLIENT spans carrying url.full) =====================

    public function nPlusOneHttp(Request $r)
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

    public function redundantHttp(Request $r)
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

    public function slowHttp(Request $r)
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

    // Many concurrent children off ONE request -> excessive_fanout.
    public function fanout(Request $r)
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

    public function chatty(Request $r)
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

    public function serialized(Request $r)
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
