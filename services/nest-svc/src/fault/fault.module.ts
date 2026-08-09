import { Module } from '@nestjs/common';
import { HttpModule } from '@nestjs/axios';
import { FaultController, FaultRouteInterceptor } from './fault.controller';
import { MessagingService } from './messaging.service';

@Module({
  imports: [
    HttpModule.register({
      timeout: 15000,
      baseURL: process.env.SELF_BASE_URL || 'http://localhost:8090',
    }),
  ],
  controllers: [FaultController],
  providers: [MessagingService, FaultRouteInterceptor],
})
export class FaultModule {}
