import { Controller, Post, Query } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { PrismaService } from '../prisma/prisma.service';
import { PgPoolService } from '../prisma/pg-pool.service';
import { firstValueFrom } from 'rxjs';

const SERVICE = 'nest-svc';
const CHANNELS = ['email', 'sms', 'push', 'webhook', 'slack', 'teams'];

function envelope(antiPattern: string, start: number, details: Record<string, unknown>) {
  return {
    antiPattern,
    service: SERVICE,
    durationMs: Date.now() - start,
    details,
    timestamp: new Date().toISOString(),
  };
}

@Controller('api/fault')
export class FaultController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly pgPool: PgPoolService,
    private readonly http: HttpService,
  ) {}

  // === SQL anti-patterns =====================================================

  @Post('n-plus-one-sql')
  async nPlusOneSql(@Query('items') items = '15') {
    const n = parseInt(items, 10) || 15;
    const start = Date.now();
    let total = 0;
    for (let orderId = 1; orderId <= n; orderId++) {
      const count = await this.prisma.orderItem.count({
        where: { orderId: BigInt(orderId) },
      });
      total += count;
    }
    return envelope('n_plus_one_sql', start, {
      items: n, orders_touched: n, items_total: total,
    });
  }

  @Post('redundant-sql')
  async redundantSql(@Query('repeats') repeats = '10') {
    const n = parseInt(repeats, 10) || 10;
    const start = Date.now();
    let total = 0;
    for (let i = 0; i < n; i++) {
      const count = await this.prisma.payment.count({
        where: { customerId: 1n },
      });
      total += count;
    }
    return envelope('redundant_sql', start, {
      repeats: n, queries_made: n, rows_seen: total,
    });
  }

  @Post('slow-sql')
  async slowSql(
    @Query('delayMs') delayMs = '600',
    @Query('repeats') repeats = '6',
  ) {
    const ms = parseInt(delayMs, 10) || 600;
    const n = parseInt(repeats, 10) || 6;
    const seconds = ms / 1000;
    const start = Date.now();
    let executed = 0;
    for (let i = 0; i < n; i++) {
      await this.prisma.$executeRawUnsafe(
        `SELECT pg_sleep(${seconds}), * FROM nest.orders ORDER BY id OFFSET ${i} LIMIT 1`,
      );
      executed++;
    }
    return envelope('slow_sql', start, {
      delayMs: ms, repeats: n, queries_executed: executed, delay_ms: ms,
    });
  }

  // Bypasses Prisma for pool-saturation because Prisma 6's internal
  // query engine serialises concurrent queries, masking the saturation
  // pattern from the OTel spans. The raw pg Pool issues truly
  // concurrent connections so the daemon sees N overlapping SQL spans
  // within a tight window — the shape its pool_saturation detector
  // requires.
  @Post('pool-saturation')
  async poolSaturation(@Query('concurrency') concurrency = '20') {
    const n = parseInt(concurrency, 10) || 20;
    const start = Date.now();
    const tasks = Array.from({ length: n }, async () => {
      const client = await this.pgPool.pool.connect();
      try {
        await client.query('SELECT pg_sleep(0.4)');
        return 1;
      } catch {
        return 0;
      } finally {
        client.release();
      }
    });
    const results = await Promise.all(tasks);
    const completed = results.reduce<number>((a, b) => a + b, 0);
    return envelope('pool_saturation', start, {
      concurrency: n, tasks_launched: n, tasks_completed: completed,
    });
  }

  // === HTTP anti-patterns ====================================================

  private async doGet(path: string): Promise<number> {
    try {
      const r = await firstValueFrom(this.http.get(path));
      return r.status === 200 ? 1 : 0;
    } catch {
      return 0;
    }
  }

  @Post('n-plus-one-http')
  async nPlusOneHttp(@Query('recipients') recipients = '10') {
    const n = parseInt(recipients, 10) || 10;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/external/mock?delayMs=0&seq=${i}&op=0`);
    }
    return envelope('n_plus_one_http', start, {
      recipients: n, calls_made: n, calls_ok: ok,
    });
  }

  @Post('redundant-http')
  async redundantHttp(@Query('repeats') repeats = '10') {
    const n = parseInt(repeats, 10) || 10;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet('/api/payments/history?customerId=1&limit=10');
    }
    return envelope('redundant_http', start, {
      repeats: n, calls_made: n, calls_ok: ok,
    });
  }

  @Post('slow-http')
  async slowHttp(
    @Query('delayMs') delayMs = '600',
    @Query('repeats') repeats = '6',
  ) {
    const ms = parseInt(delayMs, 10) || 600;
    const n = parseInt(repeats, 10) || 6;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/external/mock?delayMs=${ms}&seq=${i}&op=0`);
    }
    return envelope('slow_http', start, {
      delayMs: ms, repeats: n, calls_made: n, calls_ok: ok, delay_ms: ms,
    });
  }

  @Post('fanout')
  async fanout(@Query('width') width = '40') {
    const n = parseInt(width, 10) || 40;
    const start = Date.now();
    const tasks = Array.from({ length: n }, (_, i) =>
      this.doGet(`/api/external/mock?delayMs=10&seq=${i}&op=0`),
    );
    const results = await Promise.all(tasks);
    const ok = results.reduce((a, b) => a + b, 0);
    return envelope('excessive_fanout', start, {
      width: n, children_launched: n, children_ok: ok,
    });
  }

  @Post('chatty')
  async chatty(@Query('calls') calls = '30') {
    const n = parseInt(calls, 10) || 30;
    const start = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/external/mock?delayMs=5&seq=${i}&op=${i % 7}`);
    }
    return envelope('chatty_service', start, {
      calls: n, calls_made: n, calls_ok: ok,
    });
  }

  @Post('serialized')
  async serialized(@Query('steps') steps = '6') {
    const n = Math.min(parseInt(steps, 10) || 6, CHANNELS.length);
    const start = Date.now();
    const wcStart = Date.now();
    let ok = 0;
    for (let i = 0; i < n; i++) {
      ok += await this.doGet(`/api/dispatch/${CHANNELS[i]}?delayMs=80`);
    }
    const wallClockMs = Date.now() - wcStart;
    return envelope('serialized_calls', start, {
      steps: n, steps_ok: ok, wall_clock_ms: wallClockMs,
    });
  }
}
