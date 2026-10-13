import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Put, Query, Res } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { Audited, Public, RequirePermissions, RequiresFeature } from '../common/decorators';
import { badRequest, conflict, forbidden, notFound } from '../common/errors';
import { EXTENDED_ROLES, type RestaurantRoleName } from '../common/permissions';
import { uuidv7 } from '../common/uuid';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { hashPassword } from '../auth/auth.service';
import { DbService, Tx } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';

/** Roles an owner / IT admin can give staff from the console. The owner account itself is created at onboarding. */
const STAFF_ROLES = ['it_admin', 'cashier', 'waiter', 'chef', 'auditor'] as const;
const Pin = z.string().regex(/^\d{4,8}$/, 'PIN must be 4–8 digits');
const StaffBody = z
  .object({
    name: z.string().trim().min(1).max(80),
    role: z.enum(STAFF_ROLES),
    pin: Pin,
    phone: z.string().trim().max(20).optional(),
    // console sign-in is optional (IT admins / auditors who use the web console)
    email: z.string().trim().toLowerCase().email().optional(),
    password: z.string().min(8).max(200).optional(),
    canDiscount: z.boolean().default(false), // cashier extra permission (G cell)
  })
  .refine((b) => !b.email || !!b.password, { message: 'A password is required with an email', path: ['password'] });
const StaffPatch = z.object({
  name: z.string().trim().min(1).max(80).optional(),
  role: z.enum(STAFF_ROLES).optional(),
  pin: Pin.optional(),
  phone: z.string().trim().max(20).nullable().optional(),
  status: z.enum(['active', 'disabled']).optional(),
  canDiscount: z.boolean().optional(),
});
const CategoryPatch = z.object({ name: z.string().trim().min(1).max(60).optional(), sortOrder: z.number().int().optional() });
const ImageBody = z.object({
  contentType: z.enum(['image/jpeg', 'image/png', 'image/webp']),
  // the console resizes before upload; 1.5 MB of base64 ≈ 1.1 MB image
  dataBase64: z.string().min(16).max(1_600_000),
});
const RevokeBody = z.object({ reason: z.string().trim().min(3).max(500) });
const DashboardQuery = z.object({ days: z.coerce.number().int().min(1).max(31).default(7) });

const IST_MS = (5 * 60 + 30) * 60_000;
/** Start of the IST calendar day containing [d], as a UTC Date. */
const istDayStart = (d: Date) => new Date(Math.floor((d.getTime() + IST_MS) / 86_400_000) * 86_400_000 - IST_MS);
const istDayKey = (d: Date) => new Date(d.getTime() + IST_MS).toISOString().slice(0, 10);

/**
 * Restaurant console: everything an owner / IT admin manages from the web — overview, sales, staff with PINs,
 * devices & hubs, menu photos and deletes. Runs under RLS like the rest of the tenant API; the hub picks every
 * master-data change up on its next config pull.
 */
@ApiTags('console')
@ApiBearerAuth()
@Controller()
export class ConsoleController {
  constructor(private db: DbService, private licenses: LicenseService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  // ---------------- overview & dashboard

  @RequirePermissions('restaurant.profile.read')
  @Get('tenant/overview')
  overview(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const [tenant, branches, ent, items, categories, tables, staff, devices] = await Promise.all([
        tx.restaurantTenant.findUniqueOrThrow({ where: { id: a.tenantId } }),
        tx.branch.findMany({ orderBy: { code: 'asc' } }),
        this.licenses.entitlement(tx, a.tenantId!),
        tx.menuItem.count({ where: { deleted: false } }),
        tx.menuCategory.count({ where: { deleted: false } }),
        tx.table.count({ where: { deleted: false } }),
        tx.user.count({ where: { status: 'active' } }),
        tx.device.findMany({ where: { revokedAt: null }, select: { isHub: true, lastSeenAt: true } }),
      ]);
      const hub = devices.find((d) => d.isHub);
      const plan = ent.license ? await tx.subscriptionPlan.findUnique({ where: { id: ent.license.planId } }) : null;
      return {
        restaurant: { id: tenant.id, code: tenant.code, name: tenant.name, gstin: tenant.gstin, address: tenant.address, status: tenant.status },
        branches: branches.map((b) => ({ id: b.id, code: b.code, name: b.name, address: b.address, gstin: b.gstin })),
        license: { state: ent.state, plan: plan?.code ?? null, planName: plan?.name ?? null, features: ent.features, limits: ent.limits, endsAt: ent.license?.endsAt ?? null },
        counts: { items, categories, tables, staff, devices: devices.length },
        hub: hub ? { online: !!hub.lastSeenAt && Date.now() - hub.lastSeenAt.getTime() < 3 * 60_000, lastSeenAt: hub.lastSeenAt } : null,
      };
    });
  }

  /**
   * Sales from what the hubs synced (Build Spec: the hub is the writer; the cloud reports on synced events).
   * Totals use the latest version of each bill, so tips and reversals after billing are counted once.
   */
  @RequirePermissions('reports.read')
  @Get('tenant/dashboard')
  dashboard(@CurrentActor() a: Actor, @Query(new ZodPipe(DashboardQuery)) q: z.infer<typeof DashboardQuery>) {
    return this.t(a, async (tx) => {
      const today = istDayStart(new Date());
      const from = new Date(today.getTime() - (q.days - 1) * 86_400_000);
      const events = await tx.syncEvent.findMany({
        where: { createdAt: { gte: from }, entity: { in: ['bill', 'payment', 'order', 'order_line', 'tip_allocation'] } },
        orderBy: { createdAt: 'asc' },
        select: { entity: true, entityId: true, op: true, payload: true, createdAt: true },
      });
      type P = Record<string, unknown>;
      const bills = new Map<string, P>();
      const orders = new Set<string>();
      const lines = new Map<string, P>();
      const byMode: Record<string, number> = {};
      let tips = 0;
      for (const e of events) {
        const p = e.payload as P;
        if (e.entity === 'bill') bills.set(e.entityId, p); // later versions overwrite earlier ones
        else if (e.entity === 'order' && e.op === 'create') orders.add(e.entityId);
        else if (e.entity === 'order_line') lines.set(e.entityId, p);
        else if (e.entity === 'payment' && typeof p.amountPaise === 'number') byMode[String(p.mode)] = (byMode[String(p.mode)] ?? 0) + p.amountPaise;
        else if (e.entity === 'tip_allocation' && typeof p.amountPaise === 'number') tips += p.amountPaise;
      }
      const days: Record<string, { day: string; salesPaise: number; bills: number }> = {};
      for (let i = 0; i < q.days; i++) {
        const k = istDayKey(new Date(from.getTime() + i * 86_400_000));
        days[k] = { day: k, salesPaise: 0, bills: 0 };
      }
      let sales = 0, paidBills = 0, taxes = 0, discounts = 0, todaySales = 0, todayBills = 0;
      for (const b of bills.values()) {
        if (b.status !== 'paid') continue;
        const at = new Date(String(b.closed_at ?? b.created_at));
        const total = Number(b.total_paise ?? 0);
        sales += total;
        paidBills++;
        taxes += Number(b.cgst_paise ?? 0) + Number(b.sgst_paise ?? 0);
        discounts += Number(b.discount_paise ?? 0);
        const k = istDayKey(at);
        if (days[k]) {
          days[k].salesPaise += total;
          days[k].bills++;
        }
        if (at >= today) {
          todaySales += total;
          todayBills++;
        }
      }
      const itemQty = new Map<string, { name: string; qty: number; amountPaise: number }>();
      for (const l of lines.values()) {
        if (l.status === 'reversed') continue;
        const name = String(l.name_snapshot ?? 'Item');
        const cur = itemQty.get(name) ?? { name, qty: 0, amountPaise: 0 };
        cur.qty += Number(l.qty ?? 0);
        cur.amountPaise += Number(l.qty ?? 0) * Number(l.price_snapshot_paise ?? 0);
        itemQty.set(name, cur);
      }
      return {
        from, days: Object.values(days),
        today: { salesPaise: todaySales, bills: todayBills, avgBillPaise: todayBills ? Math.round(todaySales / todayBills) : 0 },
        period: { salesPaise: sales, bills: paidBills, orders: orders.size, taxesPaise: taxes, discountsPaise: discounts, tipsPaise: tips },
        byMode, topItems: [...itemQty.values()].sort((x, y) => y.qty - x.qty).slice(0, 8),
      };
    });
  }

  // ---------------- staff

  @RequirePermissions('staff.read')
  @Get('staff')
  staff(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) =>
      (await tx.user.findMany({ include: { roles: true }, orderBy: [{ status: 'asc' }, { name: 'asc' }] })).map((u) => ({
        id: u.id, name: u.name, email: u.email, phone: u.phone, status: u.status, hasPin: !!u.pinHash, createdAt: u.createdAt,
        role: u.roles[0]?.role ?? null, canDiscount: u.roles.some((r) => r.extraPermissions.includes('discount.apply')),
      })),
    );
  }

  private async assertRoleAllowed(tx: Tx, a: Actor, role: RestaurantRoleName) {
    if (!EXTENDED_ROLES.includes(role)) return;
    const ent = await this.licenses.entitlement(tx, a.tenantId!);
    if (!ent.features.includes('roles.extended')) throw forbidden('feature_not_in_plan', `The ${role.replace('_', ' ')} role needs the Premium plan`);
  }

  @RequirePermissions('staff.manage')
  @Audited('staff.created')
  @Post('staff')
  @ApiBody(apiBody(StaffBody))
  async createStaff(@CurrentActor() a: Actor, @Body(zbody(StaffBody)) b: z.infer<typeof StaffBody>, @AuditCtx() audit: AuditDetails) {
    if (b.role === 'it_admin' && !a.roles.includes('owner')) throw forbidden('owner_only', 'Only the owner can add IT admins');
    const [pinHash, passwordHash] = await Promise.all([hashPassword(b.pin), b.password ? hashPassword(b.password) : Promise.resolve(null)]);
    const u = await this.t(a, async (tx) => {
      await this.assertRoleAllowed(tx, a, b.role);
      if (b.email) {
        const taken = await this.db.platform((p) => Promise.all([p.user.findUnique({ where: { email: b.email } }), p.platformAdmin.findUnique({ where: { email: b.email } })]));
        if (taken[0] || taken[1]) throw conflict('email_taken', 'That email is already used');
      }
      return tx.user.create({
        data: {
          tenantId: a.tenantId!, name: b.name, phone: b.phone, email: b.email ?? null, passwordHash, pinHash,
          roles: { create: { tenantId: a.tenantId!, role: b.role, branchIds: [], extraPermissions: b.role === 'cashier' && b.canDiscount ? ['discount.apply'] : [] } },
        },
      });
    });
    // never audit the PIN or password
    Object.assign(audit, { objectType: 'user', objectId: u.id, after: { name: u.name, role: b.role, email: u.email, canDiscount: b.canDiscount } });
    return { id: u.id, name: u.name, role: b.role, status: u.status };
  }

  @RequirePermissions('staff.manage')
  @Audited('staff.updated')
  @Patch('staff/:id')
  @ApiBody(apiBody(StaffPatch))
  async updateStaff(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(StaffPatch)) b: z.infer<typeof StaffPatch>, @AuditCtx() audit: AuditDetails) {
    const pinHash = b.pin ? await hashPassword(b.pin) : undefined;
    const r = await this.t(a, async (tx) => {
      const before = await tx.user.findUnique({ where: { id }, include: { roles: true } });
      if (!before) throw notFound('Staff member');
      const role = before.roles[0];
      if (role?.role === 'owner' && (b.role || b.status === 'disabled')) throw forbidden('owner_protected', 'The owner account cannot be demoted or disabled here');
      if (id === a.id && b.status === 'disabled') throw badRequest('self_disable', 'You cannot disable your own account');
      if (b.role) await this.assertRoleAllowed(tx, a, b.role);
      if ((b.role === 'it_admin' || role?.role === 'it_admin') && !a.roles.includes('owner')) throw forbidden('owner_only', 'Only the owner can change IT admins');
      const after = await tx.user.update({
        where: { id },
        data: { name: b.name, phone: b.phone, status: b.status, ...(pinHash ? { pinHash } : {}) },
      });
      if (role && (b.role || b.canDiscount !== undefined)) {
        const nextRole = b.role ?? role.role;
        const canDiscount = b.canDiscount ?? role.extraPermissions.includes('discount.apply');
        await tx.userRoleAssignment.update({
          where: { id: role.id },
          data: { role: nextRole, extraPermissions: nextRole === 'cashier' && canDiscount ? ['discount.apply'] : [] },
        });
      }
      if (b.status === 'disabled') {
        // sign the person out everywhere in the cloud; hubs drop them on the next config pull
        await this.db.platform((p) => p.refreshToken.updateMany({ where: { subjectType: 'user', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } }));
      }
      return { before: { name: before.name, status: before.status, role: role?.role }, after: { name: after.name, status: after.status, role: b.role ?? role?.role, pinChanged: !!pinHash } };
    });
    Object.assign(audit, { objectType: 'user', objectId: id, before: r.before, after: r.after });
    return { id, ...r.after };
  }

  // ---------------- devices & hubs

  @RequirePermissions('device.manage')
  @Get('devices')
  devices(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const [devices, branches] = await Promise.all([tx.device.findMany({ orderBy: [{ isHub: 'desc' }, { pairedAt: 'desc' }] }), tx.branch.findMany()]);
      const byId = new Map(branches.map((b) => [b.id, b]));
      return devices.map((d) => ({
        id: d.id, name: d.name, platform: d.platform, isHub: d.isHub, pairedAt: d.pairedAt, lastSeenAt: d.lastSeenAt, revokedAt: d.revokedAt,
        branch: byId.get(d.branchId) ? { id: d.branchId, code: byId.get(d.branchId)!.code, name: byId.get(d.branchId)!.name } : null,
        online: !d.revokedAt && !!d.lastSeenAt && Date.now() - d.lastSeenAt.getTime() < 3 * 60_000,
      }));
    });
  }

  @RequirePermissions('device.manage')
  @Audited('device.revoked')
  @Post('devices/:id/revoke')
  @HttpCode(200)
  @ApiBody(apiBody(RevokeBody))
  async revokeDevice(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(RevokeBody)) b: z.infer<typeof RevokeBody>, @AuditCtx() audit: AuditDetails) {
    const d = await this.t(a, async (tx) => {
      const d = await tx.device.findUnique({ where: { id } });
      if (!d) throw notFound('Device');
      if (d.revokedAt) throw conflict('already_revoked', 'Device is already revoked');
      return tx.device.update({ where: { id }, data: { revokedAt: new Date(), isHub: false } });
    });
    Object.assign(audit, { branchId: d.branchId, objectType: 'device', objectId: id, after: { revokedAt: d.revokedAt }, reason: b.reason });
    return { id, revokedAt: d.revokedAt };
  }

  // ---------------- menu: categories, deletes, photos

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.category_updated')
  @Patch('menu/categories/:id')
  @ApiBody(apiBody(CategoryPatch))
  async updateCategory(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(CategoryPatch)) b: z.infer<typeof CategoryPatch>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.menuCategory.findUnique({ where: { id } });
      if (!before || before.deleted) throw notFound('Category');
      const after = await tx.menuCategory.update({ where: { id }, data: b });
      await this.bumpMenu(tx, a);
      return { before, after };
    });
    Object.assign(audit, { objectType: 'menu_category', objectId: id, before: r.before, after: r.after });
    return r.after;
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.category_deleted')
  @Delete('menu/categories/:id')
  @HttpCode(204)
  async deleteCategory(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const before = await this.t(a, async (tx) => {
      const c = await tx.menuCategory.findUnique({ where: { id } });
      if (!c || c.deleted) throw notFound('Category');
      if (await tx.menuItem.count({ where: { categoryId: id, deleted: false } })) throw conflict('category_not_empty', 'Move or delete the dishes in this category first');
      await tx.menuCategory.update({ where: { id }, data: { deleted: true } });
      await this.bumpMenu(tx, a);
      return c;
    });
    Object.assign(audit, { objectType: 'menu_category', objectId: id, before });
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.item_deleted')
  @Delete('menu/items/:id')
  @HttpCode(204)
  async deleteItem(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const before = await this.t(a, async (tx) => {
      const it = await tx.menuItem.findUnique({ where: { id } });
      if (!it || it.deleted) throw notFound('Menu item');
      await tx.menuItem.update({ where: { id }, data: { deleted: true } }); // tombstone: hubs hide it on the next pull
      await this.bumpMenu(tx, a);
      return it;
    });
    Object.assign(audit, { objectType: 'menu_item', objectId: id, before });
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.item_photo_set')
  @Put('menu/items/:id/image')
  @ApiBody(apiBody(ImageBody))
  async setImage(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(ImageBody)) b: z.infer<typeof ImageBody>, @AuditCtx() audit: AuditDetails) {
    const bytes = Buffer.from(b.dataBase64, 'base64');
    if (bytes.length < 64 || bytes.length > 1_200_000) throw badRequest('bad_image', 'Image must be between 64 bytes and 1.2 MB');
    const magic: Record<string, (x: Buffer) => boolean> = {
      'image/jpeg': (x) => x[0] === 0xff && x[1] === 0xd8,
      'image/png': (x) => x.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
      'image/webp': (x) => x.subarray(0, 4).toString('ascii') === 'RIFF' && x.subarray(8, 12).toString('ascii') === 'WEBP',
    };
    if (!magic[b.contentType](bytes)) throw badRequest('bad_image', `File is not a valid ${b.contentType}`);
    const r = await this.t(a, async (tx) => {
      const it = await tx.menuItem.findUnique({ where: { id } });
      if (!it || it.deleted) throw notFound('Menu item');
      const mediaId = uuidv7();
      await tx.media.create({ data: { id: mediaId, tenantId: a.tenantId!, contentType: b.contentType, bytes, sizeBytes: bytes.length } });
      await tx.menuItem.update({ where: { id }, data: { imageId: mediaId } });
      if (it.imageId) await tx.media.deleteMany({ where: { id: it.imageId } });
      await this.bumpMenu(tx, a);
      return { imageId: mediaId, previous: it.imageId };
    });
    Object.assign(audit, { objectType: 'menu_item', objectId: id, before: { imageId: r.previous }, after: { imageId: r.imageId, bytes: bytes.length } });
    return { id, imageId: r.imageId, imageUrl: `/api/v1/media/${r.imageId}` };
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.item_photo_removed')
  @Delete('menu/items/:id/image')
  @HttpCode(204)
  async removeImage(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const prev = await this.t(a, async (tx) => {
      const it = await tx.menuItem.findUnique({ where: { id } });
      if (!it || it.deleted) throw notFound('Menu item');
      await tx.menuItem.update({ where: { id }, data: { imageId: null } });
      if (it.imageId) await tx.media.deleteMany({ where: { id: it.imageId } });
      await this.bumpMenu(tx, a);
      return it.imageId;
    });
    Object.assign(audit, { objectType: 'menu_item', objectId: id, before: { imageId: prev } });
  }

  /** Public, cacheable menu photo by unguessable id (hubs cache it for offline use). */
  @Public()
  @Get('media/:id')
  async media(@Param('id', ParseUUIDPipe) id: string, @Res() res: Response) {
    const m = await this.db.platform((tx) => tx.media.findUnique({ where: { id } }));
    if (!m) throw notFound('Image');
    res.setHeader('content-type', m.contentType);
    res.setHeader('cache-control', 'public, max-age=31536000, immutable');
    res.setHeader('x-content-type-options', 'nosniff');
    res.send(Buffer.from(m.bytes));
  }

  // ---------------- floors

  @RequirePermissions('floor.manage')
  @RequiresFeature('tables')
  @Audited('floor.deleted')
  @Delete('floors/:id')
  @HttpCode(204)
  async deleteFloor(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const before = await this.t(a, async (tx) => {
      const f = await tx.floor.findUnique({ where: { id } });
      if (!f || f.deleted) throw notFound('Floor');
      if (a.branchIds.length && !a.branchIds.includes(f.branchId)) throw forbidden('branch_scope', 'Not your branch');
      if (await tx.table.count({ where: { floorId: id, deleted: false } })) throw conflict('floor_not_empty', 'Remove the tables on this floor first');
      await tx.floor.update({ where: { id }, data: { deleted: true } });
      return f;
    });
    Object.assign(audit, { branchId: before.branchId, objectType: 'floor', objectId: id, before });
  }

  private bumpMenu(tx: Tx, a: Actor) {
    return tx.restaurantTenant.update({ where: { id: a.tenantId }, data: { menuVersion: { increment: 1 } } });
  }
}
