// Must be imported BEFORE any NestJS or Prisma import. Sets up the
// global OTel NodeSDK with HTTP + Prisma instrumentations. Spans from
// @opentelemetry/instrumentation-http cover both server-side (Express)
// and client-side (axios via Node http module) — perf-sentinel sees
// SERVER and CLIENT spans. @prisma/instrumentation adds the `prisma`
// tracer scope on every Prisma query, which is the ORM marker the
// strict classifier consumes.
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { PrismaInstrumentation } from '@prisma/instrumentation';

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter(),
  instrumentations: [
    new HttpInstrumentation(),
    new PrismaInstrumentation(),
  ],
});

sdk.start();

process.on('SIGTERM', () => {
  sdk.shutdown().finally(() => process.exit(0));
});
