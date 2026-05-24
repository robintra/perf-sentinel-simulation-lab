import { Module } from '@nestjs/common';
import { PrismaModule } from './prisma/prisma.module';
import { FaultModule } from './fault/fault.module';
import { BusinessModule } from './business/business.module';

@Module({
  imports: [PrismaModule, FaultModule, BusinessModule],
})
export class AppModule {}
