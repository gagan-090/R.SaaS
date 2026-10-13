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
const DashboardQuery = z.object({
  range: z.enum(['today', '7d', '30d']).optional(),
  days: z.coerce.number().int().min(1).max(31).optional(), // legacy: same as range=Nd
});

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
   * Every figure uses the latest version of each bill / order / line, so tips, reversals and payments after billing
   * are counted once. The previous period of the same length is returned for comparison.
   */
  @RequirePermissions('reports.read')
  @Get('tenant/dashboard')
  dashboard(@CurrentActor() a: Actor, @Query(new ZodPipe(DashboardQuery)) q: z.infer<typeof DashboardQuery>) {
    const days = q.range === 'today' ? 1 : q.range === '30d' ? 30 : q.range === '7d' ? 7 : (q.days ?? 7);
    return this.t(a, async (tx) => {
      const today = istDayStart(new Date());
      const from = new Date(today.getTime() - (days - 1) * 86_400_000);
      const prevFrom = new Date(from.getTime() - days * 86_400_000);
      const events = await tx.syncEvent.findMany({
        // orders / lines may have been opened the day before a bill closes: look back one extra day for them
        where: { createdAt: { gte: new Date(prevFrom.getTime() - 86_400_000) }, entity: { in: ['bill', 'payment', 'order', 'order_line', 'tip_allocation', 'bill_adjustment'] } },
        orderBy: { createdAt: 'asc' },
        select: { entity: true, entityId: true, op: true, payload: true, createdAt: true },
      });
      type P = Record<string, unknown>;
      const latest = { bill: new Map<string, P>(), order: new Map<string, P>(), order_line: new Map<string, P>() };
      const payments: (P & { at: Date })[] = [], tips: (P & { at: Date })[] = [], adjustments: (P & { at: Date })[] = [];
      for (const e of events) {
        const p = e.payload as P;
        if (e.entity === 'bill' || e.entity === 'order' || e.entity === 'order_line') latest[e.entity].set(e.entityId, { ...latest[e.entity].get(e.entityId), ...p });
        else if (e.entity === 'payment') payments.push({ ...p, at: e.createdAt });
        else if (e.entity === 'tip_allocation') tips.push({ ...p, at: e.createdAt });
        else adjustments.push({ ...p, at: e.createdAt });
      }
      const [users, items, cats, tables] = await Promise.all([
        tx.user.findMany({ select: { id: true, name: true } }),
        tx.menuItem.findMany({ select: { id: true, categoryId: true } }),
        tx.menuCategory.findMany({ select: { id: true, name: true } }),
        tx.table.findMany({ select: { id: true, name: true } }),
      ]);
      const userName = new Map(users.map((u) => [u.id, u.name.split(' (')[0]]));
      const catOfItem = new Map(items.map((i) => [i.id, i.categoryId]));
      const catName = new Map(cats.map((c) => [c.id, c.name]));
      const tableName = new Map(tables.map((t) => [t.id, t.name]));
      const n = (v: unknown) => Number(v ?? 0);
      const paidAt = (b: P) => new Date(String(b.closed_at ?? b.created_at));
      const inPeriod = (d: Date) => d >= from;
      const inPrev = (d: Date) => d >= prevFrom && d < from;

      // ---- bills
      const paid = [...latest.bill.values()].filter((b) => b.status === 'paid');
      const cur = paid.filter((b) => inPeriod(paidAt(b)));
      const prev = paid.filter((b) => inPrev(paidAt(b)));
      const sum = (bs: P[], k: string) => bs.reduce((s, b) => s + n(b[k]), 0);
      const sales = sum(cur, 'total_paise'), prevSales = sum(prev, 'total_paise');

      const series: Record<string, { day: string; salesPaise: number; bills: number }> = {};
      for (let i = 0; i < days; i++) {
        const k = istDayKey(new Date(from.getTime() + i * 86_400_000));
        series[k] = { day: k, salesPaise: 0, bills: 0 };
      }
      const hourly = Array.from({ length: 24 }, (_, h) => ({ hour: h, salesPaise: 0, bills: 0 }));
      for (const b of cur) {
        const at = paidAt(b);
        const k = istDayKey(at);
        if (series[k]) {
          series[k].salesPaise += n(b.total_paise);
          series[k].bills++;
        }
        const h = new Date(at.getTime() + IST_MS).getUTCHours();
        hourly[h].salesPaise += n(b.total_paise);
        hourly[h].bills++;
      }
      const busiest = hourly.reduce((m, x) => (x.salesPaise > m.salesPaise ? x : m), hourly[0]);

      // ---- orders: type split, waiter, table
      const orderOfBill = (b: P) => latest.order.get(String(b.order_id));
      const dineIn = cur.filter((b) => orderOfBill(b)?.type !== 'takeaway');
      const ordersInPeriod = [...latest.order.values()].filter((o) => inPeriod(new Date(String(o.opened_at ?? from.toISOString()))));
      const byWaiter = new Map<string, { name: string; salesPaise: number; bills: number; tipsPaise: number }>();
      const waiterRow = (id: unknown) => {
        const key = id ? String(id) : 'none';
        if (!byWaiter.has(key)) byWaiter.set(key, { name: id ? (userName.get(String(id)) ?? 'Former staff') : 'No waiter', salesPaise: 0, bills: 0, tipsPaise: 0 });
        return byWaiter.get(key)!;
      };
      for (const b of cur) {
        const w = waiterRow(orderOfBill(b)?.waiter_id);
        w.salesPaise += n(b.total_paise);
        w.bills++;
      }
      const tipsCur = tips.filter((t) => inPeriod(t.at));
      for (const t of tipsCur) waiterRow(t.waiterId).tipsPaise += n(t.amountPaise);

      // ---- lines: dishes, categories, reversals
      const billedOrders = new Set(cur.map((b) => String(b.order_id)));
      const dish = new Map<string, { name: string; category: string; qty: number; amountPaise: number }>();
      const byCat = new Map<string, { name: string; qty: number; amountPaise: number }>();
      const reversals: { name: string; qty: number; amountPaise: number; reason: string }[] = [];
      for (const l of latest.order_line.values()) {
        const amount = n(l.qty) * n(l.price_snapshot_paise);
        if (l.status === 'reversed') {
          if (inPeriod(new Date(String(l.reversed_at ?? l.created_at ?? from.toISOString())))) {
            reversals.push({ name: String(l.name_snapshot ?? 'Item'), qty: n(l.qty), amountPaise: amount, reason: String(l.reversal_reason ?? '') });
          }
          continue;
        }
        if (!billedOrders.has(String(l.order_id))) continue; // dishes on paid bills of the period
        const category = catName.get(catOfItem.get(String(l.menu_item_id)) ?? '') ?? 'Other';
        const name = String(l.name_snapshot ?? 'Item');
        const d = dish.get(name) ?? { name, category, qty: 0, amountPaise: 0 };
        d.qty += n(l.qty);
        d.amountPaise += amount;
        dish.set(name, d);
        const c = byCat.get(category) ?? { name: category, qty: 0, amountPaise: 0 };
        c.qty += n(l.qty);
        c.amountPaise += amount;
        byCat.set(category, c);
      }
      const reasonCounts = new Map<string, number>();
      for (const r of reversals) reasonCounts.set(r.reason || 'No reason', (reasonCounts.get(r.reason || 'No reason') ?? 0) + 1);

      // ---- payments
      const byMode: Record<string, number> = {};
      for (const p of payments.filter((x) => inPeriod(x.at))) byMode[String(p.mode)] = (byMode[String(p.mode)] ?? 0) + n(p.amountPaise);

      const adjCur = adjustments.filter((x) => inPeriod(x.at));

      // ---- right now (from the latest synced state)
      // an order whose bill is paid is closed even if its own status update has not synced yet
      const paidOrders = new Set(paid.map((b) => String(b.order_id)));
      const live = [...latest.order.values()].filter((o) => (o.status === 'open' || o.status === 'billed') && !paidOrders.has(String(o.id)));
      const unpaidBills = [...latest.bill.values()].filter((b) => b.status === 'open');

      // ---- recent bills
      const recentBills = [...latest.bill.values()]
        .sort((x, y) => String(y.created_at).localeCompare(String(x.created_at)))
        .slice(0, 12)
        .map((b) => {
          const o = orderOfBill(b);
          return {
            id: b.id, invoiceNo: b.invoice_no, totalPaise: n(b.total_paise), status: b.status, createdAt: b.created_at, closedAt: b.closed_at ?? null,
            where: o?.type === 'takeaway' ? 'Takeaway' : o?.table_id ? `Table ${tableName.get(String(o.table_id)) ?? '?'}` : '—',
            waiter: o?.waiter_id ? (userName.get(String(o.waiter_id)) ?? null) : null,
          };
        });

      const pct = (c: number, p: number) => (p === 0 ? null : Math.round(((c - p) * 1000) / p) / 10);
      const kpis = {
        salesPaise: sales, bills: cur.length, avgBillPaise: cur.length ? Math.round(sales / cur.length) : 0, orders: ordersInPeriod.length,
        dineInPaise: sum(dineIn, 'total_paise'), takeawayPaise: sales - sum(dineIn, 'total_paise'),
        dineInBills: dineIn.length, takeawayBills: cur.length - dineIn.length,
        discountsPaise: sum(cur, 'discount_paise'), taxesPaise: sum(cur, 'cgst_paise') + sum(cur, 'sgst_paise'),
        tipsPaise: tipsCur.reduce((s, t) => s + n(t.amountPaise), 0),
        reversals: { count: reversals.length, amountPaise: reversals.reduce((s, r) => s + r.amountPaise, 0) },
        adjustments: { count: adjCur.length, amountPaise: adjCur.reduce((s, x) => s + n(x.amount_paise), 0) },
      };
      const todays = paid.filter((b) => paidAt(b) >= today);
      const todaySales = sum(todays, 'total_paise');
      return {
        range: q.range ?? (days === 1 ? 'today' : days === 30 ? '30d' : '7d'), dayCount: days, from,
        kpis,
        previous: { salesPaise: prevSales, bills: prev.length, avgBillPaise: prev.length ? Math.round(prevSales / prev.length) : 0 },
        change: { salesPct: pct(sales, prevSales), billsPct: pct(cur.length, prev.length) },
        series: Object.values(series), hourly, busiestHour: busiest.salesPaise > 0 ? busiest.hour : null,
        byMode,
        byCategory: [...byCat.values()].sort((x, y) => y.amountPaise - x.amountPaise),
        byWaiter: [...byWaiter.values()].sort((x, y) => y.salesPaise - x.salesPaise),
        topItems: [...dish.values()].sort((x, y) => y.qty - x.qty || y.amountPaise - x.amountPaise).slice(0, 10),
        reversals: { items: reversals.slice(-10).reverse(), reasons: [...reasonCounts.entries()].map(([reason, count]) => ({ reason, count })).sort((x, y) => y.count - x.count) },
        live: {
          openTables: live.filter((o) => o.type !== 'takeaway').length, takeaways: live.filter((o) => o.type === 'takeaway').length,
          unpaidBills: unpaidBills.length, unpaidPaise: sum(unpaidBills, 'total_paise'),
        },
        recentBills,
        // kept for older clients
        today: { salesPaise: todaySales, bills: todays.length, avgBillPaise: todays.length ? Math.round(todaySales / todays.length) : 0 },
        period: { salesPaise: sales, bills: cur.length, orders: ordersInPeriod.length, taxesPaise: kpis.taxesPaise, discountsPaise: kpis.discountsPaise, tipsPaise: kpis.tipsPaise },
        days: Object.values(series),
      };
    });
  }

  /** One bill with its lines and payments, rebuilt from synced events (drill-down from the dashboard). */
  @RequirePermissions('reports.read')
  @Get('tenant/bills/:id')
  bill(@CurrentActor() a: Actor, @Param('id') id: string) {
    return this.t(a, async (tx) => {
      const billEvents = await tx.syncEvent.findMany({ where: { entity: 'bill', entityId: id }, orderBy: { createdAt: 'asc' } });
      if (!billEvents.length) throw notFound('Bill');
      const bill = Object.assign({}, ...billEvents.map((e) => e.payload as Record<string, unknown>)) as Record<string, unknown>;
      const orderId = String(bill.order_id);
      const [orderEvents, lineEvents, payEvents, tipEvents, adjEvents] = await Promise.all([
        tx.syncEvent.findMany({ where: { entity: 'order', entityId: orderId }, orderBy: { createdAt: 'asc' } }),
        tx.syncEvent.findMany({ where: { entity: 'order_line', payload: { path: ['order_id'], equals: orderId } }, orderBy: { createdAt: 'asc' } }),
        tx.syncEvent.findMany({ where: { entity: 'payment', payload: { path: ['billId'], equals: id } }, orderBy: { createdAt: 'asc' } }),
        tx.syncEvent.findMany({ where: { entity: 'tip_allocation', payload: { path: ['billId'], equals: id } }, orderBy: { createdAt: 'asc' } }),
        tx.syncEvent.findMany({ where: { entity: 'bill_adjustment', payload: { path: ['bill_id'], equals: id } }, orderBy: { createdAt: 'asc' } }),
      ]);
      const order = Object.assign({}, ...orderEvents.map((e) => e.payload as Record<string, unknown>)) as Record<string, unknown>;
      const lines = new Map<string, Record<string, unknown>>();
      for (const e of lineEvents) lines.set(e.entityId, { ...lines.get(e.entityId), ...(e.payload as Record<string, unknown>) });
      const names = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name.split(' (')[0]]));
      const table = order.table_id ? await tx.table.findUnique({ where: { id: String(order.table_id) }, select: { name: true } }) : null;
      return {
        id, invoiceNo: bill.invoice_no, status: bill.status, createdAt: bill.created_at, closedAt: bill.closed_at ?? null,
        where: order.type === 'takeaway' ? 'Takeaway' : table ? `Table ${table.name}` : '—',
        waiter: order.waiter_id ? (names.get(String(order.waiter_id)) ?? null) : null,
        totals: {
          subtotalPaise: bill.subtotal_paise, discountPaise: bill.discount_paise, cgstPaise: bill.cgst_paise, sgstPaise: bill.sgst_paise,
          tipPaise: bill.tip_paise, roundOffPaise: bill.round_off_paise, totalPaise: bill.total_paise,
        },
        lines: [...lines.values()].map((l) => ({
          name: l.name_snapshot, qty: l.qty, pricePaise: l.price_snapshot_paise, amountPaise: Number(l.qty ?? 0) * Number(l.price_snapshot_paise ?? 0),
          status: l.status, notes: l.notes ?? null, reversalReason: l.reversal_reason ?? null,
        })),
        payments: payEvents.map((e) => {
          const p = e.payload as Record<string, unknown>;
          return { mode: p.mode, amountPaise: p.amountPaise, tenderedPaise: p.tenderedPaise ?? null, changePaise: p.changePaise ?? 0, at: p.at ?? e.createdAt };
        }),
        tips: tipEvents.map((e) => {
          const p = e.payload as Record<string, unknown>;
          return { waiter: names.get(String(p.waiterId)) ?? null, amountPaise: p.amountPaise };
        }),
        adjustments: adjEvents.map((e) => {
          const p = e.payload as Record<string, unknown>;
          return { amountPaise: p.amount_paise, reason: p.reason, at: p.at };
        }),
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
