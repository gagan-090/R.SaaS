import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { AuditDetails } from '../common/actor';
import { AuditCtx } from '../common/actor';
import { Audited, RequirePermissions } from '../common/decorators';
import { badRequest, conflict, notFound } from '../common/errors';
import { FEATURE_FLAGS } from '../common/permissions';
import { apiBody, zbody } from '../common/validation';
import { DbService } from '../db/db.service';

const flags = Object.keys(FEATURE_FLAGS);
const PlanBody = z.object({
  code: z.string().regex(/^[a-z][a-z0-9_]{2,30}$/),
  name: z.string().min(1).max(60),
  featureFlags: z.array(z.string()).refine((a) => a.every((f) => flags.includes(f)), 'unknown feature flag'),
  limits: z.record(z.string(), z.number().int().nonnegative().nullable()),
  pricePaise: z.number().int().nonnegative(),
  billingCycle: z.enum(['monthly', 'yearly']).default('monthly'),
});
const PlanPatch = PlanBody.omit({ code: true }).partial();

@ApiTags('plans')
@ApiBearerAuth()
@Controller('plans')
export class PlansController {
  constructor(private db: DbService) {}

  @RequirePermissions('platform.restaurant.read')
  @Get()
  list() {
    return this.db.platform((tx) => tx.subscriptionPlan.findMany({ orderBy: { pricePaise: 'asc' } }));
  }

  @RequirePermissions('platform.plan.manage')
  @Audited('plan.created')
  @Post()
  @ApiBody(apiBody(PlanBody))
  async create(@Body(zbody(PlanBody)) b: z.infer<typeof PlanBody>, @AuditCtx() audit: AuditDetails) {
    const plan = await this.db.platform(async (tx) => {
      if (await tx.subscriptionPlan.findUnique({ where: { code: b.code } })) throw conflict('duplicate_plan', 'Plan code exists');
      return tx.subscriptionPlan.create({ data: b });
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
    const { before, after } = await this.db.platform(async (tx) => {
      const before = await tx.subscriptionPlan.findUnique({ where: { id } });
      if (!before) throw notFound('Plan');
      return { before, after: await tx.subscriptionPlan.update({ where: { id }, data: b }) };
    });
    Object.assign(audit, { objectType: 'plan', objectId: id, before, after });
    return after;
  }
}
