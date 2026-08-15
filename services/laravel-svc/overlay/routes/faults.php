<?php

use App\Http\Controllers\BusinessController;
use App\Http\Controllers\FaultController;
use App\Http\Controllers\HealthController;
use Illuminate\Support\Facades\Route;

// Health (GET): probed by the helm deployment.
Route::get('/health/live', [HealthController::class, 'live']);
Route::get('/health/ready', [HealthController::class, 'ready']);

// Business (GET): the targets the HTTP faults call back into.
Route::get('/api/external/mock', [BusinessController::class, 'mock']);
Route::get('/api/dispatch/{channel}', [BusinessController::class, 'dispatch']);
Route::get('/api/payments/history', [BusinessController::class, 'paymentsHistory']);

// Faults (POST): the multistack 12-endpoint contract.
Route::post('/api/fault/n-plus-one-sql', [FaultController::class, 'nPlusOneSql']);
Route::post('/api/fault/n-plus-one-http', [FaultController::class, 'nPlusOneHttp']);
Route::post('/api/fault/redundant-sql', [FaultController::class, 'redundantSql']);
Route::post('/api/fault/redundant-http', [FaultController::class, 'redundantHttp']);
Route::post('/api/fault/slow-sql', [FaultController::class, 'slowSql']);
Route::post('/api/fault/slow-http', [FaultController::class, 'slowHttp']);
Route::post('/api/fault/fanout', [FaultController::class, 'fanout']);
Route::post('/api/fault/chatty', [FaultController::class, 'chatty']);
Route::post('/api/fault/serialized', [FaultController::class, 'serialized']);
Route::post('/api/fault/pool-saturation', [FaultController::class, 'poolSaturation']);
Route::post('/api/fault/n-plus-one-messaging', [FaultController::class, 'nPlusOneMessaging']);
Route::post('/api/fault/slow-messaging', [FaultController::class, 'slowMessaging']);
