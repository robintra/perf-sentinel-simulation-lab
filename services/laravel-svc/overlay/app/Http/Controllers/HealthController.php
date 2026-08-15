<?php

namespace App\Http\Controllers;

use Illuminate\Support\Facades\DB;

class HealthController extends Controller
{
    // Liveness: cheap, no DB, the process is up.
    public function live()
    {
        return response()->json(['status' => 'UP']);
    }

    // Readiness: gated on a live DB round-trip.
    public function ready()
    {
        try {
            DB::select('SELECT 1');
            return response()->json(['status' => 'UP']);
        } catch (\Throwable $e) {
            return response()->json(['status' => 'DOWN'], 503);
        }
    }
}
