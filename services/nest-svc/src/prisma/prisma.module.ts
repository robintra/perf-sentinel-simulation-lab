import { Global, Module } from '@nestjs/common';
import { PrismaService } from './prisma.service';
import { PgPoolService } from './pg-pool.service';

@Global()
@Module({
  providers: [PrismaService, PgPoolService],
  exports: [PrismaService, PgPoolService],
})
export class PrismaModule {}
