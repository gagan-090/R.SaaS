import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Put } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import { Prisma } from '@prisma/client';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { Audited, RequirePermissions, RequiresFeature } from '../common/decorators';
import { conflict, forbidden, notFound } from '../common/errors';
import { apiBody, zbody } from '../common/validation';
import { DbService, Tx } from '../db/db.service';

const Chair = z.object({ x: z.number().min(-1000).max(1000), y: z.number().min(-1000).max(1000), rotation: z.number().int().min(0).max(359).default(0) });
const LayoutTable = z.object({
  id: z.string().uuid().optional(),
  name: z.string().trim().min(1).max(20),
  seats: z.number().int().min(1).max(40),
  shape: z.enum(['round', 'square', 'rect']),
  x: z.number().int().min(0).max(10000),
  y: z.number().int().min(0).max(10000),
  width: z.number().int().min(30).max(800),
  height: z.number().int().min(30).max(800),
  rotation: z.number().int().min(0).max(359).default(0),
  chairs: z.array(Chair).max(40).nullish(),
});
const LayoutBody = z.object({
  version: z.number().int().positive(),
  width: z.number().int().min(300).max(10000),
  height: z.number().int().min(300).max(10000),
  tables: z.array(LayoutTable).max(300),
});
const StatusBody = z.object({ status: z.enum(['available', 'reserved', 'unavailable']) });

type TableRow = Prisma.TableGetPayload<object>;
const tableOut = (t: TableRow) => ({
  id: t.id, floorId: t.floorId, name: t.name, seats: t.seats, shape: t.shape, x: t.posX, y: t.posY, width: t.width, height: t.height,
  rotation: t.rotation, chairs: t.chairs, status: t.status,
});

/** Axis-aligned box around a (possibly rotated) table; circles use their radius. */
function box(t: { shape: string; x: number; y: number; width: number; height: number; rotation: number }) {
  if (t.shape === 'round') {
    const r = Math.max(t.width, t.height) / 2;
    return { l: t.x - r, r: t.x + r, t: t.y - r, b: t.y + r };
  }
  const a = (t.rotation * Math.PI) / 180;
  const hw = (Math.abs(Math.cos(a)) * t.width + Math.abs(Math.sin(a)) * t.height) / 2;
  const hh = (Math.abs(Math.sin(a)) * t.width + Math.abs(Math.cos(a)) * t.height) / 2;
  return { l: t.x - hw, r: t.x + hw, t: t.y - hh, b: t.y + hh };
}

/** Pairs of tables whose outlines overlap (a warning only — the owner decides). */
export function overlaps(tables: { name: string; shape: string; x: number; y: number; width: number; height: number; rotation: number }[]) {
  const out: { a: string; b: string }[] = [];
  const boxes = tables.map(box);
  for (let i = 0; i < tables.length; i++) {
    for (let j = i + 1; j < tables.length; j++) {
      const p = boxes[i], q = boxes[j];
      if (p.l < q.r && q.l < p.r && p.t < q.b && q.t < p.b) out.push({ a: tables[i].name, b: tables[j].name });
    }
  }
  return out;
}

/**
 * Live state of each table from what the hubs synced: an open order = occupied, a printed bill = billing.
 * Reserved / unavailable are set by staff. Orders opened within the last 14 days are considered.
 */
export async function liveTableStates(tx: Tx): Promise<Map<string, 'occupied' | 'billing'>> {
  const events = await tx.syncEvent.findMany({
    where: { entity: 'order', createdAt: { gte: new Date(Date.now() - 14 * 86_400_000) } },
    orderBy: { createdAt: 'asc' },
    select: { entityId: true, payload: true },
  });
  const latest = new Map<string, Record<string, unknown>>();
  for (const e of events) latest.set(e.entityId, { ...latest.get(e.entityId), ...(e.payload as Record<string, unknown>) });
  const out = new Map<string, 'occupied' | 'billing'>();
  for (const o of latest.values()) {
    if (!o.table_id) continue;
    if (o.status === 'open') out.set(String(o.table_id), 'occupied');
    else if (o.status === 'billed') out.set(String(o.table_id), 'billing');
  }
  return out;
}

/**
 * Visual floor editor (plan feature "floor.editor") and the live floor view every operational role can open.
 * Saving replaces the floor's tables in one transaction: tables are matched by id, new ones created, missing ones
 * retired (soft-deleted, so past orders keep their table). A table with an open order cannot be removed.
 */
@ApiTags('floors')
@ApiBearerAuth()
@Controller()
export class LayoutController {
  constructor(private db: DbService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  private async load(tx: Tx, a: Actor, floorId: string) {
    const floor = await tx.floor.findUnique({ where: { id: floorId } });
    if (!floor || floor.deleted) throw notFound('Floor');
    if (a.branchIds.length && !a.branchIds.includes(floor.branchId)) throw forbidden('branch_scope', 'Not your branch');
    const tables = await tx.table.findMany({ where: { floorId, deleted: false }, orderBy: { name: 'asc' } });
    const live = await liveTableStates(tx);
    return {
      floor: { id: floor.id, branchId: floor.branchId, name: floor.name, width: floor.width, height: floor.height, version: floor.layoutVersion },
      tables: tables.map((t) => ({ ...tableOut(t), live: live.get(t.id) ?? t.status })),
      warnings: overlaps(tables.map((t) => ({ name: t.name, shape: t.shape, x: t.posX, y: t.posY, width: t.width, height: t.height, rotation: t.rotation }))),
    };
  }

  @RequirePermissions('floor.read')
  @RequiresFeature('tables')
  @Get('floors/:id/layout')
  layout(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string) {
    return this.t(a, (tx) => this.load(tx, a, id));
  }

  @RequirePermissions('floor.manage')
  @RequiresFeature('floor.editor')
  @Audited('floor.layout_saved')
  @Put('floors/:id/layout')
  @ApiBody(apiBody(LayoutBody))
  async save(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(LayoutBody)) b: z.infer<typeof LayoutBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const floor = await tx.floor.findUnique({ where: { id } });
      if (!floor || floor.deleted) throw notFound('Floor');
      if (a.branchIds.length && !a.branchIds.includes(floor.branchId)) throw forbidden('branch_scope', 'Not your branch');
      // optimistic lock: claim the version first, so two editors saving at once cannot both win
      const claimed = await tx.floor.updateMany({ where: { id, layoutVersion: b.version }, data: { layoutVersion: { increment: 1 }, width: b.width, height: b.height } });
      if (claimed.count === 0) throw conflict('layout_changed', 'Someone else saved this floor since you opened it. Reload to see their changes.');

      const names = b.tables.map((t) => t.name.trim().toLowerCase());
      const dup = names.find((n, i) => names.indexOf(n) !== i);
      if (dup) throw conflict('duplicate_table_name', `Two tables are called "${dup}"`);
      const before = await tx.table.findMany({ where: { floorId: id, deleted: false } });
      const byId = new Map(before.map((t) => [t.id, t]));
      for (const t of b.tables) if (t.id && !byId.has(t.id)) throw notFound(`Table ${t.name}`);
      // names are unique in the branch: other floors' live tables clash; retired tables give up their name
      const others = await tx.table.findMany({ where: { branchId: floor.branchId, floorId: { not: id }, deleted: false } });
      const clash = others.find((o) => names.includes(o.name.trim().toLowerCase()));
      if (clash) throw conflict('duplicate_table_name', `Table "${clash.name}" already exists on another floor`);

      const keep = new Set(b.tables.map((t) => t.id).filter(Boolean) as string[]);
      const removed = before.filter((t) => !keep.has(t.id));
      if (removed.length) {
        const live = await liveTableStates(tx);
        const busy = removed.filter((t) => live.has(t.id));
        if (busy.length) throw conflict('table_has_open_order', `Close the open order first: ${busy.map((t) => t.name).join(', ')}`);
      }
      // free names held by retired tables (theirs become "7 (removed)"), and park the names being swapped
      const retiredClash = await tx.table.findMany({ where: { branchId: floor.branchId, deleted: true } });
      for (const t of retiredClash.filter((x) => names.includes(x.name.trim().toLowerCase()))) {
        await tx.table.update({ where: { id: t.id }, data: { name: `${t.name} (removed ${t.id.slice(-6)})` } });
      }
      for (const t of removed) await tx.table.update({ where: { id: t.id }, data: { deleted: true, name: `${t.name} (removed ${t.id.slice(-6)})` } });
      for (const t of b.tables.filter((x) => x.id)) await tx.table.update({ where: { id: t.id! }, data: { name: `~${t.id}` } });

      for (const t of b.tables) {
        const data = {
          name: t.name.trim(), seats: t.seats, shape: t.shape, posX: t.x, posY: t.y, width: t.width, height: t.height, rotation: t.rotation,
          chairs: t.chairs ? (t.chairs as Prisma.InputJsonValue) : Prisma.JsonNull,
          // legacy grid position for hubs that predate the layout editor
          layoutX: Math.max(0, Math.round((t.x - 120) / 75)), layoutY: Math.max(0, Math.round((t.y - 120) / 75)),
        };
        if (t.id) await tx.table.update({ where: { id: t.id }, data });
        else await tx.table.create({ data: { ...data, tenantId: a.tenantId!, branchId: floor.branchId, floorId: id } });
      }
      const summary = (ts: { name: string; seats: number; shape: string; x: number; y: number; rotation: number }[]) => ts.map((t) => ({ name: t.name, seats: t.seats, shape: t.shape, x: t.x, y: t.y, rotation: t.rotation }));
      return {
        branchId: floor.branchId,
        before: { width: floor.width, height: floor.height, tables: summary(before.map((t) => ({ ...t, x: t.posX, y: t.posY }))) },
        after: { width: b.width, height: b.height, tables: summary(b.tables), removed: removed.map((t) => t.name) },
        result: await this.load(tx, a, id),
      };
    });
    Object.assign(audit, { branchId: r.branchId, objectType: 'floor', objectId: id, before: r.before, after: r.after });
    return r.result;
  }

  /** Staff mark a table reserved or out of use; occupied / billing always come from orders. */
  @RequirePermissions('order.write')
  @RequiresFeature('tables')
  @Audited('table.status_changed')
  @Post('tables/:id/status')
  @HttpCode(200)
  @ApiBody(apiBody(StatusBody))
  async status(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(StatusBody)) b: z.infer<typeof StatusBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const t = await tx.table.findUnique({ where: { id } });
      if (!t || t.deleted) throw notFound('Table');
      if (a.branchIds.length && !a.branchIds.includes(t.branchId)) throw forbidden('branch_scope', 'Not your branch');
      if (b.status === 'unavailable' && (await liveTableStates(tx)).has(id)) throw conflict('table_has_open_order', 'This table has an open order');
      await tx.table.update({ where: { id }, data: { status: b.status } });
      return { t, branchId: t.branchId };
    });
    Object.assign(audit, { branchId: r.branchId, objectType: 'table', objectId: id, before: { status: r.t.status }, after: { status: b.status } });
    return { id, status: b.status };
  }
}
