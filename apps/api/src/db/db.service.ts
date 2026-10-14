import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { Prisma, PrismaClient } from '@prisma/client';

export type Tx = Prisma.TransactionClient;

/** Interactive transactions may run longer than Prisma's 5 s default on a distant database (e.g. a cloud region far
 * from the server); DB_TX_TIMEOUT_MS / DB_TX_MAX_WAIT_MS tune it (defaults 20 s / 10 s). */
const txOptions = () => ({
  timeout: Number(process.env.DB_TX_TIMEOUT_MS ?? 20_000),
  maxWait: Number(process.env.DB_TX_MAX_WAIT_MS ?? 10_000),
});

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
    }, txOptions());
  }

  async platform<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT set_config('app.platform', 'on', true)`;
      return fn(tx);
    }, txOptions());
  }

  async onModuleDestroy() {
    await this.$disconnect();
  }
}
