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

/** What a main device needs to show the branch's orders and bills (no audit or stock rows). */
export const HISTORY_ENTITIES = ['order', 'order_line', 'kitchen_ticket', 'bill', 'bill_adjustment', 'payment', 'tip_allocation'] as const;

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
    const t = await this.db.platform((tx) => tx.restaurantTenant.findUnique({ where: { id: d.tenantId }, select: { status: true } }));
    if (t?.status === 'archived' || t?.status === 'deleted') throw unauthorized('restaurant_closed', 'This restaurant is closed');
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
      // the highest invoice number this branch has used per financial year, so a new or reinstalled main device
      // continues the series instead of starting again at 000001 (invoice numbers never repeat)
      const counters = await tx.$queryRaw<{ code: string; fy: string; last: number }[]>`
        SELECT split_part(payload->>'invoice_no', '/', 1) AS code, split_part(payload->>'invoice_no', '/', 2) AS fy,
               max(split_part(payload->>'invoice_no', '/', 3)::int) AS last
        FROM sync_events
        WHERE branch_id = ${dev.branchId}::uuid AND entity = 'bill' AND payload->>'invoice_no' ~ '^[^/]+/[^/]+/[0-9]{1,9}$'
        GROUP BY 1, 2`;
      const all = [branches, floors, tables, taxRules, categories, items, variants, users].flat() as { seq: bigint }[];
      const cursor = all.reduce((m, r) => (r.seq > m ? r.seq : m), since);
      const strip = <T extends { seq: bigint }>(rows: T[]) => rows.map((r) => ({ ...r, seq: r.seq.toString() }));
      return {
        cursor: cursor.toString(),
        menuVersion: tenant.menuVersion,
        tenant: { id: tenant.id, code: tenant.code, name: tenant.name, gstin: tenant.gstin, address: tenant.address, status: tenant.status, branding: effectiveBranding(tenant.branding, ent.features) },
        licenseToken: ent.token,
        invoiceCounters: counters.map((c) => ({ branchCode: c.code, fy: c.fy, lastNumber: Number(c.last) })),
        branches: strip(branches), floors: strip(floors), tables: strip(tables), taxRules: strip(taxRules),
        categories: strip(categories), items: strip(items),
        variants: strip(variants).map((v) => ({ ...v, servingQuantity: v.servingQuantity === null ? null : Number(v.servingQuantity), portionRatio: v.portionRatio === null ? null : Number(v.portionRatio) })),
        users: users
          .filter((u) => u.roles.some((r) => r.branchIds.length === 0 || r.branchIds.includes(dev.branchId)))
          .map((u) => ({
            id: u.id, name: u.name, email: u.email, status: u.status, pinHash: u.pinHash, seq: u.seq.toString(),
            roles: u.roles.map((r) => ({
              role: r.role, extraPermissions: r.extraPermissions,
              ...(r.role === 'custom' ? { permissions: r.customRole && !r.customRole.deleted && ent.features.includes('roles.custom') ? r.customRole.permissions : [] } : {}),
            })),
          })),
      };
    });
  }

  /**
   * Orders, KOTs, bills and payments of this branch as the cloud stored them (every main device's events), oldest first,
   * after the cursor `<receivedAt ISO>|<eventId>`. A main device that took over from another one (or was reinstalled)
   * replays them so the POS shows the branch's whole bill history, and keeps it for offline use.
   */
  async history(dev: DeviceCtx, after: string | undefined, limit = 500) {
    const [t, id] = after ? after.split('|') : [];
    const since = t ? new Date(t) : null;
    return this.db.tenant(dev.tenantId, async (tx) => {
      const rows = await tx.syncEvent.findMany({
        where: {
          branchId: dev.branchId,
          entity: { in: [...HISTORY_ENTITIES] },
          ...(since && id ? { OR: [{ receivedAt: { gt: since } }, { receivedAt: since, eventId: { gt: id } }] } : {}),
        },
        orderBy: [{ receivedAt: 'asc' }, { eventId: 'asc' }],
        take: limit + 1,
      });
      const page = rows.slice(0, limit);
      const last = page.at(-1);
      return {
        events: page.map((e) => ({ eventId: e.eventId, entity: e.entity, entityId: e.entityId, op: e.op, payload: e.payload, createdAt: e.createdAt.toISOString() })),
        cursor: last ? `${last.receivedAt.toISOString()}|${last.eventId}` : (after ?? null),
        more: rows.length > limit,
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
