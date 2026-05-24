import './tracing';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const port = parseInt(process.env.HTTP_PORT || '8090', 10);
  const app = await NestFactory.create(AppModule, { logger: ['error', 'warn', 'log'] });

  app.getHttpAdapter().get('/health/live', (_req, res) => {
    res.json({ status: 'UP' });
  });
  app.getHttpAdapter().get('/health/ready', (_req, res) => {
    res.json({ status: 'UP' });
  });

  app.enableShutdownHooks();
  await app.listen(port, '0.0.0.0');
  console.log(`nest-svc listening on :${port}`);
}

bootstrap();
