import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { Audited, RequirePermissions, RequiresFeature } from '../common/decorators';
import { conflict, forbidden, notFound } from '../common/errors';
import { apiBody, zbody } from '../common/validation';
import { liveTableStates } from '../floors/layout.controller';
import { DbService, Tx } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';

const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;
const ProfileBody = z.object({
  name: z.string().trim().min(1).max(160).optional(),
  gstin: z.string().regex(GSTIN).nullable().optional(),
  address: z.string().max(500).nullable().optional(),
});
const FloorBody = z.object({ branchId: z.string().uuid(), name: z.string().trim().min(1).max(60), sortOrder: z.number().int().default(0) });
const FloorPatch = FloorBody.omit({ branchId: true }).partial();
const TableBody = z.object({
  floorId: z.string().uuid(),
  name: z.string().trim().min(1).max(20),
  seats: z.number().int().min(1).max(40).default(4),
  layoutX: z.number().int().default(0),
  layoutY: z.number().int().default(0),
});
const TablePatch = TableBody.omit({ floorId: true }).partial();
const TaxBody = z.object({ name: z.string().min(1).max(40), rateBp: z.number().int().refine((v) => [0, 500, 1200, 1800, 2800].includes(v), 'GST rate must be 0, 5, 12, 18 or 28%') });
const CategoryBody = z.object({ name: z.string().trim().min(1).max(60), sortOrder: z.number().int().default(0), branchId: z.string().uuid().nullable().optional() });

/** Branch-scoped roles only see/touch their branches (empty list = all branches). */
function assertBranch(actor: Actor, branchId: string) {
  if (actor.branchIds.length && !actor.branchIds.includes(branchId)) throw forbidden('branch_scope', 'Not your branch');
}
const branchFilter = (actor: Actor) => (actor.branchIds.length ? { in: actor.branchIds } : undefined);

/**
 * Restaurant-side setup endpoints (cloud is the single writer for this master data).
 * Every route runs inside db.tenant(...) so RLS confines it to the caller's tenant; ids from other tenants 404.
 */
@ApiTags('tenant')
@ApiBearerAuth()
@Controller()
export class TenantController {
  constructor(private db: DbService, private licenses: LicenseService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  // ---------------- profile & license

  @RequirePermissions('restaurant.profile.read')
  @Get('tenant/profile')
  profile(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.restaurantTenant.findUniqueOrThrow({ where: { id: a.tenantId } }));
  }

  @RequirePermissions('restaurant.profile.manage')
  @RequiresFeature('menu')
  @Audited('tenant.profile_updated')
  @Patch('tenant/profile')
  @ApiBody(apiBody(ProfileBody))
  async updateProfile(@CurrentActor() a: Actor, @Body(zbody(ProfileBody)) b: z.infer<typeof ProfileBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.restaurantTenant.findUniqueOrThrow({ where: { id: a.tenantId } });
      return { before, after: await tx.restaurantTenant.update({ where: { id: a.tenantId }, data: b }) };
    });
    Object.assign(audit, { objectType: 'restaurant', objectId: a.tenantId, before: r.before, after: r.after });
    return r.after;
  }

  @RequirePermissions('license.read')
  @Get('tenant/license')
  async license(@CurrentActor() a: Actor) {
    const e = await this.t(a, (tx) => this.licenses.entitlement(tx, a.tenantId!));
    return { state: e.state, readOnly: e.readOnly, features: e.features, limits: e.limits, token: e.token, endsAt: e.license?.endsAt ?? null };
  }

  @RequirePermissions('restaurant.profile.read')
  @RequiresFeature('franchise')
  @Get('branches')
  branches(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.branch.findMany({ where: { id: branchFilter(a) }, orderBy: { code: 'asc' } }));
  }

  // ---------------- floors & tables

  @RequirePermissions('floor.read')
  @RequiresFeature('tables')
  @Get('floors')
  floors(@CurrentActor() a: Actor) {
    return this.t(a, (tx) =>
      tx.floor.findMany({ where: { deleted: false, branchId: branchFilter(a) }, include: { tables: { where: { deleted: false } } }, orderBy: { sortOrder: 'asc' } }),
    );
  }

  @RequirePermissions('floor.manage')
  @RequiresFeature('tables')
  @Audited('floor.created')
  @Post('floors')
  @ApiBody(apiBody(FloorBody))
  async createFloor(@CurrentActor() a: Actor, @Body(zbody(FloorBody)) b: z.infer<typeof FloorBody>, @AuditCtx() audit: AuditDetails) {
    assertBranch(a, b.branchId);
    const f = await this.t(a, async (tx) => {
      if (!(await tx.branch.findUnique({ where: { id: b.branchId } }))) throw notFound('Branch');
      const lim = (await this.licenses.entitlement(tx, a.tenantId!)).limits.floorsPerBranch;
      const count = await tx.floor.count({ where: { branchId: b.branchId, deleted: false } });
      if (typeof lim === 'number' && count >= lim) throw forbidden('plan_limit', `Your plan allows ${lim} floor(s) per branch`);
      return tx.floor.create({ data: { ...b, tenantId: a.tenantId! } });
    });
    Object.assign(audit, { branchId: f.branchId, objectType: 'floor', objectId: f.id, after: f });
    return f;
  }

  @RequirePermissions('floor.manage')
  @RequiresFeature('tables')
  @Audited('floor.updated')
  @Patch('floors/:id')
  @ApiBody(apiBody(FloorPatch))
  async updateFloor(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(FloorPatch)) b: z.infer<typeof FloorPatch>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.floor.findUnique({ where: { id } });
      if (!before || before.deleted) throw notFound('Floor');
      assertBranch(a, before.branchId);
      return { before, after: await tx.floor.update({ where: { id }, data: b }) };
    });
    Object.assign(audit, { branchId: r.after.branchId, objectType: 'floor', objectId: id, before: r.before, after: r.after });
    return r.after;
  }

  @RequirePermissions('floor.read')
  @RequiresFeature('tables')
  @Get('tables')
  tables(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.table.findMany({ where: { deleted: false, branchId: branchFilter(a) }, orderBy: { name: 'asc' } }));
  }

  @RequirePermissions('floor.manage')
  @RequiresFeature('tables')
  @Audited('table.created')
  @Post('tables')
  @ApiBody(apiBody(TableBody))
  async createTable(@CurrentActor() a: Actor, @Body(zbody(TableBody)) b: z.infer<typeof TableBody>, @AuditCtx() audit: AuditDetails) {
    const t = await this.t(a, async (tx) => {
      const floor = await tx.floor.findUnique({ where: { id: b.floorId } });
      if (!floor || floor.deleted) throw notFound('Floor');
      assertBranch(a, floor.branchId);
      if (await tx.table.findFirst({ where: { branchId: floor.branchId, name: b.name, deleted: false } })) throw conflict('duplicate_table_name', `Table "${b.name}" already exists`);
      const retired = await tx.table.findFirst({ where: { branchId: floor.branchId, name: b.name, deleted: true } });
      if (retired) await tx.table.update({ where: { id: retired.id }, data: { name: `${retired.name} (removed ${retired.id.slice(-6)})` } });
      // next free spot on the floor plan (6 per row), shaped by seats; the layout editor can move it
      const n = await tx.table.count({ where: { floorId: b.floorId, deleted: false } });
      const shape = b.seats >= 6 ? 'rect' : b.seats <= 2 ? 'round' : 'square';
      return tx.table.create({
        data: {
          ...b, tenantId: a.tenantId!, branchId: floor.branchId, shape, width: shape === 'rect' ? 140 : 80, height: 80,
          posX: 120 + (n % 6) * 160, posY: 120 + Math.floor(n / 6) * 160,
        },
      });
    });
    Object.assign(audit, { branchId: t.branchId, objectType: 'table', objectId: t.id, after: t });
    return t;
  }

  @RequirePermissions('floor.manage')
  @RequiresFeature('tables')
  @Audited('table.updated')
  @Patch('tables/:id')
  @ApiBody(apiBody(TablePatch))
  async updateTable(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(TablePatch)) b: z.infer<typeof TablePatch>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.table.findUnique({ where: { id } });
      if (!before || before.deleted) throw notFound('Table');
      assertBranch(a, before.branchId);
      return { before, after: await tx.table.update({ where: { id }, data: b }) };
    });
    Object.assign(audit, { branchId: r.after.branchId, objectType: 'table', objectId: id, before: r.before, after: r.after });
    return r.after;
  }

  @RequirePermissions('floor.manage')
  @RequiresFeature('tables')
  @Audited('table.deleted')
  @Delete('tables/:id')
  @HttpCode(204)
  async deleteTable(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const before = await this.t(a, async (tx) => {
      const before = await tx.table.findUnique({ where: { id } });
      if (!before || before.deleted) throw notFound('Table');
      assertBranch(a, before.branchId);
      if ((await liveTableStates(tx)).has(id)) throw conflict('table_has_open_order', `Table ${before.name} has an open order; close it first`);
      // soft delete so hubs pull the tombstone and past orders keep the table; the name is freed for a new table
      await tx.table.update({ where: { id }, data: { deleted: true, name: `${before.name} (removed ${id.slice(-6)})` } });
      return before;
    });
    Object.assign(audit, { branchId: before.branchId, objectType: 'table', objectId: id, before });
  }

  // ---------------- tax & menu

  @RequirePermissions('menu.read')
  @RequiresFeature('menu')
  @Get('tax-rules')
  taxRules(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.taxRule.findMany({ where: { deleted: false }, orderBy: { rateBp: 'asc' } }));
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('tax_rule.created')
  @Post('tax-rules')
  @ApiBody(apiBody(TaxBody))
  async createTaxRule(@CurrentActor() a: Actor, @Body(zbody(TaxBody)) b: z.infer<typeof TaxBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, (tx) => tx.taxRule.create({ data: { ...b, tenantId: a.tenantId! } }));
    Object.assign(audit, { objectType: 'tax_rule', objectId: r.id, after: r });
    return r;
  }

  @RequirePermissions('menu.read')
  @RequiresFeature('menu')
  @Get('menu/categories')
  categories(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.menuCategory.findMany({ where: { deleted: false }, orderBy: { sortOrder: 'asc' } }));
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.category_created')
  @Post('menu/categories')
  @ApiBody(apiBody(CategoryBody))
  async createCategory(@CurrentActor() a: Actor, @Body(zbody(CategoryBody)) b: z.infer<typeof CategoryBody>, @AuditCtx() audit: AuditDetails) {
    if (b.branchId) assertBranch(a, b.branchId);
    const c = await this.t(a, (tx) => tx.menuCategory.create({ data: { ...b, tenantId: a.tenantId! } }));
    Object.assign(audit, { objectType: 'menu_category', objectId: c.id, after: c });
    return c;
  }

  // ---------------- staff (read) & audit

  @RequirePermissions('staff.read')
  @Get('users')
  users(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) =>
      (await tx.user.findMany({ include: { roles: true }, orderBy: { name: 'asc' } })).map((u) => ({
        id: u.id, name: u.name, email: u.email, phone: u.phone, status: u.status,
        roles: u.roles.map((r) => ({ role: r.role, branchIds: r.branchIds })),
      })),
    );
  }

  @RequirePermissions('audit.read')
  @Get('audit')
  audit(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.auditEvent.findMany({ orderBy: { at: 'desc' }, take: 200 }));
  }
}
