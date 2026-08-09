import { Injectable } from '@nestjs/common';
import { SpanKind, SpanStatusCode, trace } from '@opentelemetry/api';
import { ChannelModel, ConfirmChannel, connect } from 'amqplib';

const DESTINATION = 'perfsim.nest-svc';
const ROUTING_KEY = 'nest-svc';
const CONFIRM_TIMEOUT_MS = 5_000;
const TOXIPROXY_TIMEOUT_MS = 5_000;

type Session = {
  connection: ChannelModel;
  channel: ConfirmChannel;
  returned: () => boolean;
};

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function port(name: string, fallback: number): number {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isInteger(value) || value < 1 || value > 65_535) {
    throw new Error(`${name} must be a valid port`);
  }
  return value;
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

async function bounded<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out`)), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

@Injectable()
export class MessagingService {
  private readonly tracer = trace.getTracer(MessagingService.name);

  async publishSequentially(messages: number) {
    const timeoutMs = CONFIRM_TIMEOUT_MS;
    const session = await this.openSession(
      process.env.RABBITMQ_HOST ?? 'rabbitmq.messaging.svc.cluster.local',
      port('RABBITMQ_PORT', 5_672),
      timeoutMs,
    );
    try {
      const gate = Promise.withResolvers<void>();
      const confirmations: Promise<void>[] = [];
      for (let index = 0; index < messages; index++) {
        confirmations.push(
          this.producerSpan(async () => {
            await this.publish(session.channel, `nest-message-${index}`, timeoutMs);
            await gate.promise;
          }),
        );
      }
      const allConfirmed = Promise.all(confirmations);
      void allConfirmed.catch(() => undefined);
      try {
        await bounded(session.channel.waitForConfirms(), timeoutMs, 'RabbitMQ confirmations');
        if (session.returned()) throw new Error('RabbitMQ returned a mandatory message');
        gate.resolve();
      } catch (error) {
        gate.reject(error);
      }
      await bounded(allConfirmed, timeoutMs, 'RabbitMQ publisher acknowledgements');
      return { published: messages, confirmed: messages };
    } finally {
      await this.closeSession(session, timeoutMs);
    }
  }

  async publishSlowly(delayMs: number, repeats: number) {
    await this.updateLatency(delayMs);
    const timeoutMs = delayMs + CONFIRM_TIMEOUT_MS;
    const session = await this.openSession(
      process.env.RABBITMQ_SLOW_HOST ?? 'toxiproxy.messaging.svc.cluster.local',
      port('RABBITMQ_SLOW_PORT', 25_672),
      timeoutMs,
    );
    try {
      for (let index = 0; index < repeats; index++) {
        await this.producerSpan(async () => {
          const returnedBefore = session.returned();
          const confirmation = this.publish(
            session.channel,
            `slow-nest-message-${index}`,
            timeoutMs,
          );
          await bounded(session.channel.waitForConfirms(), timeoutMs, 'RabbitMQ confirmation');
          await confirmation;
          if (!returnedBefore && session.returned()) {
            throw new Error('RabbitMQ returned a mandatory message');
          }
        });
      }
      return { published: repeats, confirmed: repeats, delay_ms: delayMs };
    } finally {
      await this.closeSession(session, timeoutMs);
    }
  }

  private async producerSpan<T>(operation: () => Promise<T>): Promise<T> {
    return this.tracer.startActiveSpan(
      `${DESTINATION} send`,
      {
        kind: SpanKind.PRODUCER,
        attributes: {
          'messaging.system': 'rabbitmq',
          'messaging.destination.name': DESTINATION,
          'messaging.operation.type': 'send',
        },
      },
      async (span) => {
        try {
          return await operation();
        } catch (error) {
          const exception = asError(error);
          span.recordException(exception);
          span.setStatus({ code: SpanStatusCode.ERROR, message: exception.message });
          throw exception;
        } finally {
          span.end();
        }
      },
    );
  }

  private publish(channel: ConfirmChannel, payload: string, timeoutMs: number): Promise<void> {
    const acknowledgement = new Promise<void>((resolve, reject) => {
      channel.publish(
        DESTINATION,
        ROUTING_KEY,
        Buffer.from(payload),
        { persistent: true, mandatory: true, contentType: 'text/plain' },
        (error) => (error ? reject(asError(error)) : resolve()),
      );
    });
    return bounded(acknowledgement, timeoutMs, 'RabbitMQ publisher acknowledgement');
  }

  private async openSession(host: string, rabbitPort: number, timeoutMs: number): Promise<Session> {
    const username = encodeURIComponent(requiredEnv('RABBITMQ_USERNAME'));
    const password = encodeURIComponent(requiredEnv('RABBITMQ_PASSWORD'));
    const setupTimeoutMs = timeoutMs * 8;
    const connection = await bounded(
      connect(`amqp://${username}:${password}@${host}:${rabbitPort}`, {
        timeout: setupTimeoutMs,
      }),
      setupTimeoutMs,
      'RabbitMQ connection setup',
    );
    let channel: ConfirmChannel | undefined;
    try {
      channel = await bounded(
        connection.createConfirmChannel(),
        timeoutMs,
        'RabbitMQ channel setup',
      );
      await bounded(
        channel.assertExchange(DESTINATION, 'direct', { durable: true }),
        timeoutMs,
        'RabbitMQ exchange declaration',
      );
      await bounded(
        channel.assertQueue(DESTINATION, {
          durable: true,
          arguments: { 'x-message-ttl': 60_000 },
        }),
        timeoutMs,
        'RabbitMQ queue declaration',
      );
      await bounded(
        channel.bindQueue(DESTINATION, DESTINATION, ROUTING_KEY),
        timeoutMs,
        'RabbitMQ queue binding',
      );
      let returned = false;
      channel.on('return', () => {
        returned = true;
      });
      return { connection, channel, returned: () => returned };
    } catch (error) {
      if (channel) await bounded(channel.close(), timeoutMs, 'RabbitMQ channel close').catch(() => {});
      await bounded(connection.close(), timeoutMs, 'RabbitMQ connection close').catch(() => {});
      throw error;
    }
  }

  private async closeSession(session: Session, timeoutMs: number): Promise<void> {
    let failure: unknown;
    try {
      await bounded(session.channel.close(), timeoutMs, 'RabbitMQ channel close');
    } catch (error) {
      failure = error;
    }
    try {
      await bounded(session.connection.close(), timeoutMs, 'RabbitMQ connection close');
    } catch (error) {
      failure ??= error;
    }
    if (failure) throw failure;
  }

  private async updateLatency(delayMs: number): Promise<void> {
    const api = (process.env.TOXIPROXY_API ??
      'http://toxiproxy.messaging.svc.cluster.local:8474').replace(/\/$/, '');
    const updateUrl = `${api}/proxies/rabbitmq-slow/toxics/latency_downstream`;
    const attributes = { attributes: { latency: delayMs, jitter: 0 } };
    let response = await this.toxiproxyRequest(updateUrl, attributes);
    if (response.status === 404) {
      response = await this.toxiproxyRequest(`${api}/proxies/rabbitmq-slow/toxics`, {
        name: 'latency_downstream',
        type: 'latency',
        stream: 'downstream',
        attributes: { latency: delayMs, jitter: 0 },
      });
      if (response.status === 409) response = await this.toxiproxyRequest(updateUrl, attributes);
    }
    if (!response.ok) throw new Error(`Toxiproxy returned HTTP ${response.status}`);
  }

  private toxiproxyRequest(url: string, body: object): Promise<Response> {
    return fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TOXIPROXY_TIMEOUT_MS),
    });
  }
}
