import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { Prisma, PrismaClient } from '@prisma/client';

export type Tx = Prisma.TransactionClient;

/**
 * All data access goes through one of these two doors so Postgres RLS always has a context:
 *  - tenant(tenantId, fn): restaurant-scoped; RLS limits every row to that tenant.
 *  - platform(fn): platform admin / system work that is allowed to cross tenants.
 * Settings are transaction-local (set_config(..., true)) so pooled connections never leak context.
 */
@Injectable()
export class DbService extends PrismaClient implements OnModuleDestroy {
  async tenant<T>(tenantId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
    if (!tenantId) throw new Error('tenant context requires a tenantId');
    return this.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT set_config('app.tenant_id', ${tenantId}, true)`;
      return fn(tx);
    });
  }

  async platform<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT set_config('app.platform', 'on', true)`;
      return fn(tx);
    });
  }

  async onModuleDestroy() {
    await this.$disconnect();
  }
}
