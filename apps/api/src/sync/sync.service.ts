import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { sha256 } from '../common/crypto';
import { unauthorized } from '../common/errors';
import { DbService } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';
import { effectiveBranding } from '../tenant/branding';
import { InventoryService } from '../inventory/inventory.service';

/** Entities the hub is the single writer for (Kitchen Playbook §05). Anything else is rejected into sync_conflicts. */
export const HUB_ENTITIES = [
  'order', 'order_line', 'order_status', 'table_transfer', 'kitchen_ticket', 'bill', 'bill_adjustment',
  'payment', 'tip_allocation', 'stock_movement', 'shift', 'break', 'audit_event',
] as const;

export interface PushEvent {
  eventId: string;
  entity: string;
  entityId: string;
  op: string;
  payload: Record<string, unknown>;
  createdAt: string;
}
export type PushResult = { eventId: string; result: 'accepted' | 'duplicate' | 'rejected'; reason?: string };

export interface DeviceCtx {
  deviceId: string;
  tenantId: string;
  branchId: string;
}

@Injectable()
export class SyncService {
  constructor(private db: DbService, private licenses: LicenseService, private inventory: InventoryService) {}

  async authenticateDevice(token: string | undefined): Promise<DeviceCtx> {
    if (!token) throw unauthorized('missing_device_token', 'X-Device-Token header required');
    const d = await this.db.platform((tx) => tx.device.findUnique({ where: { deviceTokenHash: sha256(token) } }));
    if (!d || d.revokedAt) throw unauthorized('invalid_device_token', 'Unknown or revoked device');
    await this.db.tenant(d.tenantId, (tx) => tx.device.update({ where: { id: d.id }, data: { lastSeenAt: new Date() } }));
    return { deviceId: d.id, tenantId: d.tenantId, branchId: d.branchId };
  }

  /** Exactly-once storage: event_id is the primary key; a replayed event returns "duplicate" and writes nothing. */
  async push(dev: DeviceCtx, events: PushEvent[]): Promise<PushResult[]> {
    return this.db.tenant(dev.tenantId, async (tx) => {
      const out: PushResult[] = [];
      let inventory: boolean | undefined;
      for (const e of events) {
        const existing = await tx.syncEvent.findUnique({ where: { eventId: e.eventId } });
        const conflict = existing ? null : await tx.syncConflict.findUnique({ where: { eventId: e.eventId } });
        if (existing || conflict) {
          out.push({ eventId: e.eventId, result: existing ? 'duplicate' : 'rejected', reason: conflict?.reason });
          continue;
        }
        const reason = !(HUB_ENTITIES as readonly string[]).includes(e.entity)
          ? `entity "${e.entity}" is not hub-owned`
          : e.payload?.branchId && e.payload.branchId !== dev.branchId
            ? 'event belongs to another branch'
            : null;
        if (reason) {
          await tx.syncConflict.create({
            data: { tenantId: dev.tenantId, branchId: dev.branchId, eventId: e.eventId, reason, payload: e as unknown as Prisma.InputJsonValue },
          });
          out.push({ eventId: e.eventId, result: 'rejected', reason });
          continue;
        }
        await tx.syncEvent.create({
          data: {
            eventId: e.eventId, tenantId: dev.tenantId, branchId: dev.branchId, entity: e.entity, entityId: e.entityId,
            op: e.op, payload: e.payload as Prisma.InputJsonValue, createdAt: new Date(e.createdAt),
          },
        });
        out.push({ eventId: e.eventId, result: 'accepted' });
        // a paid bill takes its dishes' ingredients out of stock (once per line, whatever the retries)
        if (e.entity === 'bill' && e.payload?.status === 'paid' && e.payload?.order_id) {
          inventory ??= (await this.licenses.entitlement(tx, dev.tenantId)).features.includes('inventory');
          if (inventory) await this.inventory.deductForPaidBill(tx, dev.tenantId, { id: e.entityId, order_id: String(e.payload.order_id) });
        }
      }
      return out;
    });
  }

  /** Config changes since the cursor (a global sequence bumped on every insert/update of cloud-owned config). */
  async pull(dev: DeviceCtx, since: bigint) {
    return this.db.tenant(dev.tenantId, async (tx) => {
      const gt = { gt: since };
      const [branches, floors, tables, taxRules, categories, items, variants, users, ent, tenant] = await Promise.all([
        tx.branch.findMany({ where: { id: dev.branchId, seq: gt } }),
        tx.floor.findMany({ where: { branchId: dev.branchId, seq: gt } }),
        tx.table.findMany({ where: { branchId: dev.branchId, seq: gt } }),
        tx.taxRule.findMany({ where: { seq: gt } }),
        tx.menuCategory.findMany({ where: { seq: gt, OR: [{ branchId: null }, { branchId: dev.branchId }] } }),
        tx.menuItem.findMany({ where: { seq: gt } }),
        tx.menuVariant.findMany({ where: { seq: gt } }),
        tx.user.findMany({ where: { OR: [{ seq: gt }, { roles: { some: { seq: gt } } }] }, include: { roles: { include: { customRole: true } } } }),
        this.licenses.entitlement(tx, dev.tenantId),
        tx.restaurantTenant.findUniqueOrThrow({ where: { id: dev.tenantId } }),
      ]);
      const all = [branches, floors, tables, taxRules, categories, items, variants, users].flat() as { seq: bigint }[];
      const cursor = all.reduce((m, r) => (r.seq > m ? r.seq : m), since);
      const strip = <T extends { seq: bigint }>(rows: T[]) => rows.map((r) => ({ ...r, seq: r.seq.toString() }));
      return {
        cursor: cursor.toString(),
        menuVersion: tenant.menuVersion,
        tenant: { id: tenant.id, name: tenant.name, gstin: tenant.gstin, address: tenant.address, status: tenant.status, branding: effectiveBranding(tenant.branding, ent.features) },
        licenseToken: ent.token,
        branches: strip(branches), floors: strip(floors), tables: strip(tables), taxRules: strip(taxRules),
        categories: strip(categories), items: strip(items),
        variants: strip(variants).map((v) => ({ ...v, servingQuantity: v.servingQuantity === null ? null : Number(v.servingQuantity), portionRatio: v.portionRatio === null ? null : Number(v.portionRatio) })),
        users: users
          .filter((u) => u.roles.some((r) => r.branchIds.length === 0 || r.branchIds.includes(dev.branchId)))
          .map((u) => ({
            id: u.id, name: u.name, status: u.status, pinHash: u.pinHash, seq: u.seq.toString(),
            roles: u.roles.map((r) => ({
              role: r.role, extraPermissions: r.extraPermissions,
              ...(r.role === 'custom' ? { permissions: r.customRole && !r.customRole.deleted && ent.features.includes('roles.custom') ? r.customRole.permissions : [] } : {}),
            })),
          })),
      };
    });
  }

  async status(dev: DeviceCtx) {
    return this.db.tenant(dev.tenantId, async (tx) => {
      const [last, total, conflicts] = await Promise.all([
        tx.syncEvent.findFirst({ where: { branchId: dev.branchId }, orderBy: { receivedAt: 'desc' } }),
        tx.syncEvent.count({ where: { branchId: dev.branchId } }),
        tx.syncConflict.count({ where: { branchId: dev.branchId, resolvedBy: null } }),
      ]);
      return { lastPushAt: last?.receivedAt ?? null, storedEvents: total, openConflicts: conflicts };
    });
  }
}
