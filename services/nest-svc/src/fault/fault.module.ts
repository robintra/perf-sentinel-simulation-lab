import { Module } from '@nestjs/common';
import { HttpModule } from '@nestjs/axios';
import { FaultController } from './fault.controller';

@Module({
  imports: [
    HttpModule.register({
      timeout: 15000,
      baseURL: process.env.SELF_BASE_URL || 'http://localhost:8090',
    }),
  ],
  controllers: [FaultController],
})
export class FaultModule {}
