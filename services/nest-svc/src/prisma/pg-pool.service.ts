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
    // Strip the Prisma-specific `?schema=` param (pg Pool ignores it)
    // and force search_path via the PostgreSQL startup `options` param
    // so any future raw query on unqualified table names resolves to
    // the `nest` schema.
    const rawUrl = (process.env.DATABASE_URL || '').replace(/[?&]schema=[^&]*/g, '');
    this.pool = new Pool({
      connectionString: rawUrl || undefined,
      max: 10,
      options: '-csearch_path=nest,public',
    });
  }

  async onModuleDestroy() {
    await this.pool.end();
  }
}
