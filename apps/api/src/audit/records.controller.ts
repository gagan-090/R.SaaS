import { Controller, Get, Query, Res } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { z } from 'zod';
import type { Actor } from '../common/actor';
import { CurrentActor } from '../common/actor';
import { RequireAnyPermission, RequirePermissions } from '../common/decorators';
import { forbidden } from '../common/errors';
import { ZodPipe } from '../common/validation';
import { DbService, Tx } from '../db/db.service';

/** Audit modules (filters) by action prefix. */
export const MODULES: Record<string, string[]> = {
  'Sign-in & access': ['auth.', 'mfa.'],
  'Employees & roles': ['staff.', 'role.'],
  'Menu & prices': ['menu.', 'tax_rule.'],
  'Floor layout': ['floor.', 'table.'],
  'Purchases & receipts': ['inventory.purchase', 'inventory.request'],
  Inventory: ['inventory.'],
  Expenses: ['expense.'],
  Imports: ['import.'],
  'Settings & devices': ['tenant.', 'device.'],
  'POS (orders, bills, approvals)': ['pos.'],
};
const moduleOf = (action: string) => Object.entries(MODULES).find(([, ps]) => ps.some((p) => action.startsWith(p)))?.[0] ?? 'Other';

const AuditQuery = z.object({
  from: z.string().optional(),
  to: z.string().optional(),
  actorId: z.string().uuid().optional(),
  role: z.string().max(40).optional(),
  module: z.string().max(60).optional(),
  action: z.string().max(80).optional(),
  q: z.string().max(80).optional(), // object id, request id or reason text
  limit: z.coerce.number().int().min(1).max(2000).default(300),
});
const RangeQuery = z.object({ from: z.string().optional(), to: z.string().optional() });
type P = Record<string, unknown>;

const dateRange = (from?: string, to?: string) => ({
  ...(from ? { gte: new Date(from) } : {}),
  ...(to ? { lt: new Date(new Date(to).getTime() + (to.length <= 10 ? 86_400_000 : 0)) } : {}),
});
const csvCell = (s: unknown) => {
  const v = s === null || s === undefined ? '' : typeof s === 'object' ? JSON.stringify(s) : String(s);
  const safe = /^[=+\-@]/.test(v) ? `'${v}` : v; // no formula injection when opened in Excel
  return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
};

/**
 * Read-only restaurant records: the audit log (cloud actions + POS actions synced from the hub), sales records from
 * synced bills, live orders, and import history. Nothing here can change a record; audit rows are append-only in
 * the database itself. Credentials, PINs, tokens and card data never reach the audit rows (redacted on write).
 */
@ApiTags('records')
@ApiBearerAuth()
@Controller()
export class RecordsController {
  constructor(private db: DbService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  private async events(tx: Tx, q: z.infer<typeof AuditQuery>) {
    const at = dateRange(q.from, q.to);
    const users = await tx.user.findMany({ select: { id: true, name: true, roles: { select: { role: true, customRole: { select: { name: true } } } } } });
    const userName = new Map(users.map((u) => [u.id, u.name]));
    const userRole = new Map(users.map((u) => [u.id, u.roles.map((r) => (r.role === 'custom' ? `custom:${r.customRole?.name ?? ''}` : r.role)).join(',')]));
    const prefixes = q.module ? MODULES[q.module] : undefined;
    const cloud = prefixes?.every((p) => p === 'pos.') ? [] : await tx.auditEvent.findMany({
      where: {
        ...(Object.keys(at).length ? { at } : {}),
        ...(q.actorId ? { actorId: q.actorId } : {}),
        AND: [
          q.action ? { action: q.action } : prefixes ? { OR: prefixes.map((p) => ({ action: { startsWith: p } })) } : {},
          q.q ? { OR: [{ objectId: q.q }, { requestId: q.q }, { reason: { contains: q.q, mode: 'insensitive' as const } }] } : {},
        ],
      },
      orderBy: { at: 'desc' },
      take: q.limit,
    });
    // actions taken on the POS (reversals, approvals, discounts, prints…) arrive as synced hub audit events
    const posWanted = !prefixes || prefixes.includes('pos.');
    const pos = posWanted && (!q.action || q.action.startsWith('pos.'))
      ? await tx.syncEvent.findMany({ where: { entity: 'audit_event', ...(Object.keys(at).length ? { createdAt: at } : {}) }, orderBy: { createdAt: 'desc' }, take: q.limit })
      : [];
    const rows = [
      ...cloud.map((e) => ({
        id: e.id, source: 'cloud', at: e.at.toISOString(), action: e.action, module: moduleOf(e.action), actorId: e.actorId, actorType: e.actorType,
        actorName: e.actorName ?? (e.actorId ? (userName.get(e.actorId) ?? null) : null) ?? (e.actorType === 'system' ? 'System' : 'Unknown'),
        actorRole: e.actorRole ?? (e.actorId ? userRole.get(e.actorId) ?? null : null), objectType: e.objectType, objectId: e.objectId,
        before: e.before, after: e.after, reason: e.reason, requestId: e.requestId, ip: e.ip, deviceId: e.deviceId,
      })),
      ...pos.map((e) => {
        const p = e.payload as P;
        const actor = p.actor ? String(p.actor) : null;
        const parse = (x: unknown) => {
          try {
            return typeof x === 'string' ? JSON.parse(x) : x ?? null;
          } catch {
            return x;
          }
        };
        return {
          id: e.eventId, source: 'pos', at: String(p.at ?? e.createdAt.toISOString()), action: `pos.${String(p.action ?? 'event')}`, module: 'POS (orders, bills, approvals)',
          actorId: actor, actorType: 'user', actorName: actor ? (userName.get(actor) ?? 'Former staff') : 'System', actorRole: actor ? userRole.get(actor) ?? null : null,
          objectType: (p.object_type as string) ?? null, objectId: (p.object_id as string) ?? null, before: parse(p.before_json), after: parse(p.after_json),
          reason: (p.reason as string) ?? null, requestId: e.eventId, ip: null, deviceId: (p.device_id as string) ?? null,
        };
      }),
    ]
      .filter((r) => !q.actorId || r.actorId === q.actorId)
      .filter((r) => !q.role || (r.actorRole ?? '').split(',').some((x) => x === q.role || x.startsWith(`${q.role}:`)))
      .filter((r) => !q.q || r.objectId === q.q || r.requestId === q.q || (r.reason ?? '').toLowerCase().includes(q.q.toLowerCase()) || r.source === 'cloud')
      .sort((x, y) => (x.at < y.at ? 1 : -1))
      .slice(0, q.limit);
    return rows;
  }

  /** The restaurant's audit log, newest first, with filters for date, employee, role, module, action and record. */
  @RequirePermissions('audit.read')
  @Get('audit/events')
  auditEvents(@CurrentActor() a: Actor, @Query(new ZodPipe(AuditQuery)) q: z.infer<typeof AuditQuery>) {
    return this.t(a, (tx) => this.events(tx, q));
  }

  @RequirePermissions('audit.read', 'audit.export')
  @Get('audit/events.csv')
  async auditCsv(@CurrentActor() a: Actor, @Query(new ZodPipe(AuditQuery)) q: z.infer<typeof AuditQuery>, @Res() res: Response) {
    const rows = await this.t(a, (tx) => this.events(tx, { ...q, limit: Math.max(q.limit, 2000) }));
    const head = ['time_utc', 'source', 'module', 'action', 'employee', 'role', 'record_type', 'record_id', 'reason', 'before', 'after', 'request_id', 'ip'];
    const lines = [head.join(','), ...rows.map((r) => [r.at, r.source, r.module, r.action, r.actorName, r.actorRole, r.objectType, r.objectId, r.reason, r.before, r.after, r.requestId, r.ip].map(csvCell).join(','))];
    res.setHeader('content-type', 'text/csv; charset=utf-8');
    res.setHeader('content-disposition', `attachment; filename="audit-log-${new Date().toISOString().slice(0, 10)}.csv"`);
    res.send('﻿' + lines.join('\r\n'));
  }

  /** Values for the audit filters: employees (with their current role), modules and the actions seen so far. */
  @RequirePermissions('audit.read')
  @Get('audit/facets')
  facets(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const [users, actions] = await Promise.all([
        tx.user.findMany({ select: { id: true, name: true, status: true, roles: { select: { role: true } } }, orderBy: { name: 'asc' } }),
        tx.auditEvent.findMany({ distinct: ['action'], select: { action: true }, orderBy: { action: 'asc' } }),
      ]);
      return {
        employees: users.map((u) => ({ id: u.id, name: u.name, status: u.status, role: u.roles[0]?.role ?? null })),
        roles: ['owner', 'it_admin', 'cashier', 'waiter', 'chef', 'auditor', 'custom'],
        modules: Object.keys(MODULES),
        actions: actions.map((x) => x.action),
      };
    });
  }

  /** Import history for auditors (who imported what, when, file details, counts, errors and outcome). */
  @RequirePermissions('audit.read')
  @Get('audit/imports')
  imports(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const jobs = await tx.importJob.findMany({ orderBy: { createdAt: 'desc' }, take: 200 });
      const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
      return jobs.map((j) => ({
        id: j.id, kind: j.kind, mode: j.mode, fileName: j.fileName, fileSize: j.fileSize, fileSha256: j.fileSha256, status: j.status, counts: j.counts,
        result: j.result, errors: (j.errors as unknown as { severity: string }[]).filter((e) => e.severity === 'error').length,
        actorName: users.get(j.actorId) ?? 'Former staff', actorRole: j.actorRole, createdAt: j.createdAt, committedAt: j.committedAt,
      }));
    });
  }

  private async sales(tx: Tx, q: z.infer<typeof RangeQuery>) {
    const range = dateRange(q.from ?? new Date(Date.now() - 86_400_000).toISOString().slice(0, 10), q.to);
    const events = await tx.syncEvent.findMany({
      where: { entity: { in: ['bill', 'payment', 'bill_adjustment', 'order', 'order_line', 'tip_allocation'] }, createdAt: range },
      orderBy: { createdAt: 'asc' },
    });
    const bills = new Map<string, P>(), orders = new Map<string, P>(), lines = new Map<string, P>();
    const payments: P[] = [], adjustments: P[] = [];
    for (const e of events) {
      const p = e.payload as P;
      if (e.entity === 'bill') bills.set(e.entityId, { ...bills.get(e.entityId), ...p, id: e.entityId });
      else if (e.entity === 'order') orders.set(e.entityId, { ...orders.get(e.entityId), ...p });
      else if (e.entity === 'order_line') lines.set(e.entityId, { ...lines.get(e.entityId), ...p });
      else if (e.entity === 'payment') payments.push({ ...p, at: p.at ?? e.createdAt.toISOString() });
      else if (e.entity === 'bill_adjustment') adjustments.push({ ...p, at: p.at ?? e.createdAt.toISOString() });
    }
    const n = (v: unknown) => Number(v ?? 0);
    const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
    const billRows = [...bills.values()].map((b) => ({
      id: b.id, invoiceNo: b.invoice_no ?? null, status: b.status, orderId: b.order_id, orderType: orders.get(String(b.order_id))?.type ?? null,
      subtotalPaise: n(b.subtotal_paise), discountPaise: n(b.discount_paise), discountReason: b.discount_reason ?? null, taxPaise: n(b.cgst_paise) + n(b.sgst_paise),
      tipPaise: n(b.tip_paise), totalPaise: n(b.total_paise), createdAt: b.created_at ?? null, closedAt: b.closed_at ?? null,
      payments: payments.filter((p) => p.billId === b.id).map((p) => ({ mode: p.mode, amountPaise: n(p.amountPaise), at: p.at, reference: p.reference ?? null })),
      adjustments: adjustments.filter((x) => x.bill_id === b.id).map((x) => ({ type: x.type ?? 'correction', amountPaise: n(x.amount_paise), reason: x.reason, approvedBy: x.approved_by ? users.get(String(x.approved_by)) ?? 'Former staff' : null, at: x.at })),
    })).sort((x, y) => String(y.closedAt ?? y.createdAt ?? '').localeCompare(String(x.closedAt ?? x.createdAt ?? '')));
    const voids = [...lines.values()].filter((l) => l.status === 'reversed').map((l) => ({
      orderId: l.order_id, name: l.name_snapshot, qty: n(l.qty), amountPaise: n(l.qty) * n(l.price_snapshot_paise), reason: l.reversal_reason ?? null,
      by: l.reversed_by ? users.get(String(l.reversed_by)) ?? 'Former staff' : null, approvedBy: l.reversal_approved_by ? users.get(String(l.reversal_approved_by)) ?? 'Former staff' : null, at: l.reversed_at ?? null,
    }));
    const paid = billRows.filter((b) => b.status === 'paid');
    const byMode: Record<string, number> = {};
    for (const p of payments) byMode[String(p.mode)] = (byMode[String(p.mode)] ?? 0) + n(p.amountPaise);
    return {
      from: range.gte?.toISOString() ?? null, to: range.lt?.toISOString() ?? null,
      summary: {
        bills: billRows.length, paidBills: paid.length, salesPaise: paid.reduce((s, b) => s + b.totalPaise, 0),
        discountsPaise: billRows.reduce((s, b) => s + b.discountPaise, 0), tipsPaise: paid.reduce((s, b) => s + b.tipPaise, 0),
        refundsPaise: adjustments.filter((x) => n(x.amount_paise) < 0).reduce((s, x) => s + n(x.amount_paise), 0),
        voids: voids.length, voidsPaise: voids.reduce((s, v) => s + v.amountPaise, 0), paymentsByMode: byMode,
      },
      bills: billRows, voids,
    };
  }

  /** Bills, payments, discounts, refunds / corrections and voided lines in a date range (synced from the POS). */
  @RequirePermissions('order.read')
  @RequireAnyPermission('reports.read', 'payment.take', 'audit.read')
  @Get('records/sales')
  salesRecords(@CurrentActor() a: Actor, @Query(new ZodPipe(RangeQuery)) q: z.infer<typeof RangeQuery>) {
    return this.t(a, (tx) => this.sales(tx, q));
  }

  @RequirePermissions('order.read', 'audit.export')
  @Get('records/sales.csv')
  async salesCsv(@CurrentActor() a: Actor, @Query(new ZodPipe(RangeQuery)) q: z.infer<typeof RangeQuery>, @Res() res: Response) {
    const s = await this.t(a, (tx) => this.sales(tx, q));
    const head = ['invoice', 'status', 'type', 'subtotal', 'discount', 'discount_reason', 'tax', 'tip', 'total', 'paid_at', 'payments', 'adjustments'];
    const r = (p: number) => (p / 100).toFixed(2);
    const lines = [head.join(','), ...s.bills.map((b) => [
      b.invoiceNo, b.status, b.orderType, r(b.subtotalPaise), r(b.discountPaise), b.discountReason, r(b.taxPaise), r(b.tipPaise), r(b.totalPaise), b.closedAt,
      b.payments.map((p) => `${String(p.mode)} ${r(p.amountPaise)}`).join('; '), b.adjustments.map((x) => `${r(x.amountPaise)} ${String(x.reason ?? '')}`).join('; '),
    ].map(csvCell).join(','))];
    res.setHeader('content-type', 'text/csv; charset=utf-8');
    res.setHeader('content-disposition', `attachment; filename="sales-${new Date().toISOString().slice(0, 10)}.csv"`);
    res.send('﻿' + lines.join('\r\n'));
  }

  /** Open and billed orders with their lines (kitchen, cashier and waiter views), from what the hub synced. */
  @RequirePermissions('order.read')
  @Get('records/live-orders')
  liveOrders(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const since = new Date(Date.now() - 2 * 86_400_000);
      const events = await tx.syncEvent.findMany({ where: { entity: { in: ['order', 'order_line', 'kitchen_ticket'] }, createdAt: { gte: since } }, orderBy: { createdAt: 'asc' } });
      const orders = new Map<string, P>(), lines = new Map<string, P>(), tickets = new Map<string, P>();
      for (const e of events) {
        const m = e.entity === 'order' ? orders : e.entity === 'order_line' ? lines : tickets;
        m.set(e.entityId, { ...m.get(e.entityId), ...(e.payload as P), id: e.entityId });
      }
      const tables = new Map((await tx.table.findMany({ select: { id: true, name: true } })).map((t) => [t.id, t.name]));
      const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
      return [...orders.values()]
        .filter((o) => o.status === 'open' || o.status === 'billed')
        .map((o) => ({
          id: o.id, type: o.type, status: o.status, table: o.table_id ? tables.get(String(o.table_id)) ?? null : null, openedAt: o.opened_at ?? null,
          waiter: o.waiter_id ? users.get(String(o.waiter_id)) ?? null : null,
          lines: [...lines.values()].filter((l) => l.order_id === o.id).map((l) => ({ name: l.name_snapshot, qty: Number(l.qty ?? 0), status: l.status, notes: l.notes ?? null })),
          kitchen: [...tickets.values()].filter((k) => k.order_id === o.id).map((k) => ({ kotNo: k.kot_no, status: k.status })),
        }))
        .sort((x, y) => String(x.openedAt ?? '').localeCompare(String(y.openedAt ?? '')));
    });
  }
}

