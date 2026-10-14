import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { Audited, RequirePermissions, RequiresFeature } from '../common/decorators';
import { conflict, forbidden, notFound } from '../common/errors';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService, Tx } from '../db/db.service';

export const EXPENSE_CATEGORIES = ['Rent', 'Utilities', 'Salaries', 'Repairs', 'Supplies', 'Marketing', 'Transport', 'Fees & licences', 'Other'] as const;
const ExpenseBody = z.object({
  category: z.enum(EXPENSE_CATEGORIES),
  description: z.string().trim().min(1).max(200),
  amountPaise: z.number().int().positive().max(10_000_000_000),
  paidOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD'),
  paymentMode: z.enum(['cash', 'upi', 'card', 'bank', 'other']),
  supplierId: z.string().uuid().nullish(),
  reference: z.string().trim().max(80).nullish(),
});
const VoidBody = z.object({ reason: z.string().trim().min(3).max(300) });
const ListQuery = z.object({ from: z.string().optional(), to: z.string().optional(), includeVoided: z.enum(['true', 'false']).default('false') });

/** Expenses (plan feature "expenses"). Money in paise. A wrong entry is voided with a reason, never deleted. */
@ApiTags('expenses')
@ApiBearerAuth()
@Controller('expenses')
export class ExpensesController {
  constructor(private db: DbService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  @RequirePermissions('expense.read')
  @Get()
  list(@CurrentActor() a: Actor, @Query(new ZodPipe(ListQuery)) q: z.infer<typeof ListQuery>) {
    return this.t(a, async (tx) => {
      const rows = await tx.expense.findMany({
        where: {
          ...(q.includeVoided === 'true' ? {} : { voidedAt: null }),
          ...(q.from || q.to ? { paidOn: { ...(q.from ? { gte: new Date(q.from) } : {}), ...(q.to ? { lte: new Date(q.to) } : {}) } } : {}),
        },
        orderBy: [{ paidOn: 'desc' }, { createdAt: 'desc' }],
        take: 500,
      });
      const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
      const live = rows.filter((r) => !r.voidedAt);
      return {
        totalPaise: live.reduce((s, r) => s + r.amountPaise, 0),
        byCategory: EXPENSE_CATEGORIES.map((c) => ({ category: c, amountPaise: live.filter((r) => r.category === c).reduce((s, r) => s + r.amountPaise, 0) })).filter((x) => x.amountPaise > 0),
        items: rows.map((r) => ({ ...r, paidOn: r.paidOn.toISOString().slice(0, 10), createdByName: users.get(r.createdBy) ?? 'Former staff' })),
        categories: EXPENSE_CATEGORIES,
      };
    });
  }

  @RequirePermissions('expense.write')
  @RequiresFeature('expenses')
  @Audited('expense.created')
  @Post()
  @ApiBody(apiBody(ExpenseBody))
  async create(@CurrentActor() a: Actor, @Body(zbody(ExpenseBody)) b: z.infer<typeof ExpenseBody>, @AuditCtx() audit: AuditDetails) {
    const e = await this.t(a, async (tx) => {
      if (b.supplierId && !(await tx.supplier.findUnique({ where: { id: b.supplierId } }))) throw notFound('Supplier');
      return tx.expense.create({ data: { ...b, paidOn: new Date(b.paidOn), tenantId: a.tenantId!, createdBy: a.id } });
    });
    Object.assign(audit, { objectType: 'expense', objectId: e.id, after: { category: e.category, description: e.description, amountPaise: e.amountPaise, paidOn: b.paidOn, paymentMode: e.paymentMode } });
    return { ...e, paidOn: b.paidOn };
  }

  @RequirePermissions('expense.write')
  @RequiresFeature('expenses')
  @Audited('expense.voided')
  @Post(':id/void')
  @HttpCode(200)
  @ApiBody(apiBody(VoidBody))
  async void(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(VoidBody)) b: z.infer<typeof VoidBody>, @AuditCtx() audit: AuditDetails) {
    const e = await this.t(a, async (tx) => {
      const before = await tx.expense.findUnique({ where: { id } });
      if (!before) throw notFound('Expense');
      if (before.voidedAt) throw conflict('already_voided', 'This expense is already voided');
      return tx.expense.update({ where: { id }, data: { voidedAt: new Date(), voidedBy: a.id, voidReason: b.reason } });
    });
    Object.assign(audit, { objectType: 'expense', objectId: id, reason: b.reason, before: { amountPaise: e.amountPaise, category: e.category }, after: { voided: true } });
    return { id, voided: true };
  }
}
