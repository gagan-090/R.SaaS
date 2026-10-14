import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { AuditDetails } from '../common/actor';
import { AuditCtx } from '../common/actor';
import { Audited, RequirePermissions } from '../common/decorators';
import { badRequest, conflict, notFound } from '../common/errors';
import { FEATURE_FLAGS } from '../common/permissions';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';

const flags = Object.keys(FEATURE_FLAGS);
const PlanBody = z.object({
  code: z.string().regex(/^[a-z][a-z0-9_]{2,30}$/),
  name: z.string().min(1).max(60),
  featureFlags: z.array(z.string()).refine((a) => a.every((f) => flags.includes(f)), 'unknown feature flag'),
  limits: z.record(z.string(), z.number().int().nonnegative().nullable()),
  pricePaise: z.number().int().nonnegative(), // per month
  yearlyPricePaise: z.number().int().nonnegative().optional(), // per year; default 12 × monthly
  tier: z.number().int().min(1).max(1000).optional(), // order: Standard 1 < Professional 2 < Premium 3
  billingCycle: z.enum(['monthly', 'yearly']).default('monthly'), // cycle offered first
});
const PlanPatch = PlanBody.omit({ code: true }).extend({ archived: z.boolean() }).partial();
const ListQuery = z.object({ includeArchived: z.enum(['true', 'false']).default('false') });

@ApiTags('plans')
@ApiBearerAuth()
@Controller('plans')
export class PlansController {
  constructor(private db: DbService, private licenses: LicenseService) {}

  @RequirePermissions('platform.restaurant.read')
  @Get()
  async list(@Query(new ZodPipe(ListQuery)) q: z.infer<typeof ListQuery>) {
    return this.db.platform(async (tx) => {
      const plans = await tx.subscriptionPlan.findMany({
        where: q.includeArchived === 'true' ? {} : { archived: false },
        orderBy: [{ archived: 'asc' }, { tier: 'asc' }, { pricePaise: 'asc' }, { name: 'asc' }],
        include: { _count: { select: { licenses: { where: { status: 'active' } } } } },
      });
      // activeLicenses: how many restaurants are on the plan right now (shown before archiving / repricing)
      return plans.map(({ _count, ...p }) => ({ ...p, activeLicenses: _count.licenses }));
    });
  }

  @RequirePermissions('platform.plan.manage')
  @Audited('plan.created')
  @Post()
  @ApiBody(apiBody(PlanBody))
  async create(@Body(zbody(PlanBody)) b: z.infer<typeof PlanBody>, @AuditCtx() audit: AuditDetails) {
    const plan = await this.db.platform(async (tx) => {
      if (await tx.subscriptionPlan.findUnique({ where: { code: b.code } })) throw conflict('duplicate_plan', 'Plan code exists');
      const tier = b.tier ?? ((await tx.subscriptionPlan.aggregate({ _max: { tier: true }, where: { tier: { lt: 100 } } }))._max.tier ?? 0) + 1;
      return tx.subscriptionPlan.create({ data: { ...b, tier, yearlyPricePaise: b.yearlyPricePaise ?? b.pricePaise * 12 } });
    });
    Object.assign(audit, { objectType: 'plan', objectId: plan.id, after: plan });
    return plan;
  }

  @RequirePermissions('platform.plan.manage')
  @Audited('plan.updated')
  @Patch(':id')
  @ApiBody(apiBody(PlanPatch))
  async update(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(PlanPatch)) b: z.infer<typeof PlanPatch>, @AuditCtx() audit: AuditDetails) {
    if (Object.keys(b).length === 0) throw badRequest('empty_patch', 'Nothing to update');
    const { before, after, licensesUpdated } = await this.db.platform(async (tx) => {
      const before = await tx.subscriptionPlan.findUnique({ where: { id } });
      if (!before) throw notFound('Plan');
      const after = await tx.subscriptionPlan.update({ where: { id }, data: b });
      // Features and limits apply to restaurants already on this plan: re-sign their active licenses (same dates).
      // Hubs receive the new token on their next pull (about a minute).
      let licensesUpdated = 0;
      if (b.featureFlags || b.limits) {
        for (const lic of await tx.license.findMany({ where: { planId: id, status: 'active' } })) {
          await tx.license.update({ where: { id: lic.id }, data: { signedToken: this.licenses.buildToken(lic, after) } });
          licensesUpdated++;
        }
      }
      return { before, after, licensesUpdated };
    });
    Object.assign(audit, { objectType: 'plan', objectId: id, before, after: { ...after, licensesUpdated } });
    return { ...after, licensesUpdated };
  }
}
