import { HttpService } from '@nestjs/axios';
import { INestApplication } from '@nestjs/common';
import { Span, trace } from '@opentelemetry/api';
import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, describe, expect, it, jest } from '@jest/globals';
import request from 'supertest';
import { FaultController } from './fault.controller';
import { MessagingService } from './messaging.service';
import { PgPoolService } from '../prisma/pg-pool.service';
import { PrismaService } from '../prisma/prisma.service';

describe('messaging invalid contract', () => {
  let app: INestApplication;
  const publishSequentially = jest.fn(async (messages: number) => ({
    published: messages,
    confirmed: messages,
  }));
  const publishSlowly = jest.fn(async (delayMs: number, repeats: number) => ({
    published: repeats,
    confirmed: repeats,
    delay_ms: delayMs,
  }));
  const databaseTripwire = jest.fn();
  const httpTripwire = jest.fn();

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [FaultController],
      providers: [
        {
          provide: PrismaService,
          useValue: {
            orderItem: { count: databaseTripwire },
            payment: { count: databaseTripwire },
            $executeRawUnsafe: databaseTripwire,
          },
        },
        { provide: PgPoolService, useValue: { pool: { connect: databaseTripwire } } },
        { provide: HttpService, useValue: { get: httpTripwire } },
        {
          provide: MessagingService,
          useValue: { publishSequentially, publishSlowly },
        },
      ],
    }).compile();
    app = module.createNestApplication();
    await app.listen(0, '127.0.0.1');
  });

  afterAll(async () => {
    await app.close();
  });

  it('returns 400 for all invalid bounds without crossing any external boundary', async () => {
    const invalid = [
      '/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq',
      '/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq',
      '/api/fault/n-plus-one-messaging?messages=8&broker=unsupported',
    ];

    for (const path of invalid) {
      await request(app.getHttpServer()).post(path).expect(400);
    }

    expect(publishSequentially).not.toHaveBeenCalled();
    expect(publishSlowly).not.toHaveBeenCalled();
    expect(databaseTripwire).not.toHaveBeenCalled();
    expect(httpTripwire).not.toHaveBeenCalled();
    process.stdout.write(
      'PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0\n',
    );
  });

  it('rejects malformed scalar and array query values before crossing a boundary', async () => {
    const malformed = [
      '/api/fault/n-plus-one-messaging?messages=8x&broker=rabbitmq',
      '/api/fault/n-plus-one-messaging?messages=8&messages=9&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=600x&repeats=3&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=600&repeats=3&repeats=4&broker=rabbitmq',
      '/api/fault/slow-messaging?delayMs=600&repeats=3&broker=rabbitmq&broker=rabbitmq',
    ];

    for (const path of malformed) {
      await request(app.getHttpServer()).post(path).expect(400);
    }

    expect(publishSequentially).not.toHaveBeenCalled();
    expect(publishSlowly).not.toHaveBeenCalled();
    expect(databaseTripwire).not.toHaveBeenCalled();
    expect(httpTripwire).not.toHaveBeenCalled();
  });

  it('returns HTTP 200 and exact confirmation counts for valid messaging requests', async () => {
    await request(app.getHttpServer())
      .post('/api/fault/n-plus-one-messaging?messages=8&broker=rabbitmq')
      .expect(200)
      .expect(({ body }) => expect(body.details).toEqual({ published: 8, confirmed: 8 }));
    await request(app.getHttpServer())
      .post('/api/fault/slow-messaging?delayMs=600&repeats=3&broker=rabbitmq')
      .expect(200)
      .expect(({ body }) =>
        expect(body.details).toEqual({ published: 3, confirmed: 3, delay_ms: 600 }),
      );
  });

  it('returns a generic 500 without exposing broker connection details', async () => {
    publishSequentially.mockRejectedValueOnce(
      new Error('amqp://test-user:secret-value@rabbitmq.invalid'),
    );
    await request(app.getHttpServer())
      .post('/api/fault/n-plus-one-messaging?messages=8&broker=rabbitmq')
      .expect(500)
      .expect(({ body }) => {
        expect(body.message).toBe('RabbitMQ operation failed');
        expect(JSON.stringify(body)).not.toContain('secret-value');
      });
  });

  it('sets the canonical route on the active server span through one controller interceptor', async () => {
    const setAttribute = jest.fn();
    const activeSpan = { setAttribute } as unknown as Span;
    const activeSpanSpy = jest.spyOn(trace, 'getActiveSpan').mockReturnValue(activeSpan);
    try {
      await request(app.getHttpServer())
        .post('/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq')
        .expect(400);
      expect(setAttribute).toHaveBeenCalledWith(
        'http.route',
        '/api/fault/n-plus-one-messaging',
      );
    } finally {
      activeSpanSpy.mockRestore();
    }
  });
});
