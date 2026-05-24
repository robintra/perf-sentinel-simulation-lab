import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { Pool } from 'pg';

// Raw pg Pool for the pool-saturation endpoint. Prisma 6's internal
// query engine serialises concurrent queries, masking pool saturation
// from the OTel spans. The daemon's pool_saturation detector needs N
// overlapping SQL spans within a tight window — only a raw Pool with
// independent connections achieves that shape.
@Injectable()
export class PgPoolService implements OnModuleDestroy {
  readonly pool: Pool;

  constructor() {
    this.pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 10,
    });
  }

  async onModuleDestroy() {
    await this.pool.end();
  }
}
