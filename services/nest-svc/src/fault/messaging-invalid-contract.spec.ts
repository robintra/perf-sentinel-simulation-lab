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

const amqplib = require('amqplib') as typeof import('amqplib');

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

  it('returns HTTP 200 for the historical fault handlers too', async () => {
    await request(app.getHttpServer()).post('/api/fault/n-plus-one-sql?items=1').expect(200);
  });

  it('observes a slow publisher nack before waiting and still closes the session', async () => {
    const channelClose = jest.fn(async () => undefined);
    const connectionClose = jest.fn(async () => undefined);
    const channel = {
      assertExchange: jest.fn(async () => undefined),
      assertQueue: jest.fn(async () => undefined),
      bindQueue: jest.fn(async () => undefined),
      on: jest.fn().mockReturnThis(),
      publish: jest.fn((...args: unknown[]) => {
        const callback = args[4] as (error: Error) => void;
        queueMicrotask(() => callback(new Error('publisher nack')));
        return true;
      }),
      waitForConfirms: jest.fn(
        () =>
          new Promise<void>((_, reject) =>
            queueMicrotask(() => reject(new Error('group nack'))),
          ),
      ),
      close: channelClose,
    };
    const connection = {
      createConfirmChannel: jest.fn(async () => channel),
      close: connectionClose,
    };
    const connectSpy = jest.spyOn(amqplib, 'connect').mockResolvedValue(connection as never);
    const fetchSpy = jest.spyOn(global, 'fetch').mockResolvedValue({ status: 200, ok: true } as Response);
    const previousUsername = process.env.RABBITMQ_USERNAME;
    const previousPassword = process.env.RABBITMQ_PASSWORD;
    process.env.RABBITMQ_USERNAME = 'test-user';
    process.env.RABBITMQ_PASSWORD = 'test-password';
    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on('unhandledRejection', onUnhandled);
    let realServiceApp: INestApplication | undefined;
    try {
      const module = await Test.createTestingModule({
        controllers: [FaultController],
        providers: [
          MessagingService,
          { provide: PrismaService, useValue: {} },
          { provide: PgPoolService, useValue: {} },
          { provide: HttpService, useValue: {} },
        ],
      }).compile();
      realServiceApp = module.createNestApplication();
      await realServiceApp.listen(0, '127.0.0.1');
      await request(realServiceApp.getHttpServer())
        .post('/api/fault/slow-messaging?delayMs=600&repeats=3&broker=rabbitmq')
        .expect(500)
        .expect(({ body }) => expect(body.message).toBe('RabbitMQ operation failed'));
      await new Promise<void>((resolve) => setImmediate(resolve));
      expect(unhandled).toEqual([]);
      expect(channelClose).toHaveBeenCalledTimes(1);
      expect(connectionClose).toHaveBeenCalledTimes(1);
    } finally {
      await realServiceApp?.close();
      process.off('unhandledRejection', onUnhandled);
      connectSpy.mockRestore();
      fetchSpy.mockRestore();
      if (previousUsername === undefined) delete process.env.RABBITMQ_USERNAME;
      else process.env.RABBITMQ_USERNAME = previousUsername;
      if (previousPassword === undefined) delete process.env.RABBITMQ_PASSWORD;
      else process.env.RABBITMQ_PASSWORD = previousPassword;
    }
  });
});
