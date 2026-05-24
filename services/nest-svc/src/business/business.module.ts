import { Module } from '@nestjs/common';
import { BusinessController } from './business.controller';

@Module({
  controllers: [BusinessController],
})
export class BusinessModule {}
