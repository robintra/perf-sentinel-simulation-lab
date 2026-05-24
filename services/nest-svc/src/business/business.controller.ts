import { Controller, Get, Query, Res, HttpStatus } from '@nestjs/common';
import { Response } from 'express';
import { PrismaService } from '../prisma/prisma.service';

@Controller('api')
export class BusinessController {
  private static readonly CHANNELS = new Set([
    'email', 'sms', 'push', 'webhook', 'slack', 'teams',
  ]);

  constructor(private readonly prisma: PrismaService) {}

  @Get('external/mock')
  async mock(
    @Query('delayMs') delayMs = '0',
    @Query('seq') seq = '0',
    @Query('op') op = '0',
  ) {
    const d = parseInt(delayMs, 10) || 0;
    if (d > 0) await sleep(d);
    return { ok: true, seq: parseInt(seq, 10), op: parseInt(op, 10), delayMs: d };
  }

  @Get('dispatch/:channel')
  async dispatch(
    @Query('delayMs') delayMs = '0',
    @Res() res: Response,
  ) {
    const channel = res.req.params.channel;
    if (!BusinessController.CHANNELS.has(channel)) {
      return res.status(HttpStatus.NOT_FOUND).json({ error: 'unknown channel' });
    }
    const d = parseInt(delayMs, 10) || 0;
    if (d > 0) await sleep(d);
    return res.json({ channel, dispatched: true, delayMs: d });
  }

  @Get('payments/history')
  async paymentsHistory(
    @Query('customerId') customerId = '1',
    @Query('limit') limit = '10',
  ) {
    const cid = BigInt(parseInt(customerId, 10) || 1);
    const safeLimit = Math.min(Math.max(parseInt(limit, 10) || 10, 1), 100);
    const rows = await this.prisma.payment.findMany({
      where: { customerId: cid },
      orderBy: { id: 'asc' },
      take: safeLimit,
    });
    return rows.map((p) => [
      Number(p.id), Number(p.orderId), Number(p.customerId),
      Number(p.amountCents), p.status,
    ]);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
