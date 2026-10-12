import { Body, Controller, Get, Headers, HttpCode, Post, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { randomToken, sha256 } from '../common/crypto';
import { Audited, Public, RequirePermissions, RequiresFeature } from '../common/decorators';
import { forbidden, notFound } from '../common/errors';
import { zbody, ZodPipe } from '../common/validation';
import { DbService } from '../db/db.service';
import { SyncService } from './sync.service';

const RegisterHubBody = z.object({
  branchId: z.string().uuid(),
  name: z.string().min(1).max(60),
  platform: z.enum(['windows', 'android']),
});
const PushBody = z.object({
  events: z
    .array(
      z.object({
        eventId: z.string().uuid(),
        entity: z.string().min(1).max(40),
        entityId: z.string().min(1).max(64),
        op: z.string().min(1).max(20),
        payload: z.record(z.string(), z.unknown()),
        createdAt: z.string().datetime({ offset: true }),
      }),
    )
    .max(200),
});
const PullQuery = z.object({ since: z.string().regex(/^\d+$/).default('0') });

@ApiTags('sync')
@Controller()
export class SyncController {
  constructor(private sync: SyncService, private db: DbService) {}

  /** IT Admin/Owner registers this branch's hub device; the returned token is shown once and stored only as a hash. */
  @RequirePermissions('device.manage')
  @RequiresFeature('offline.single')
  @Audited('device.hub_registered')
  @Post('devices/register-hub')
  async registerHub(@CurrentActor() a: Actor, @Body(zbody(RegisterHubBody)) b: z.infer<typeof RegisterHubBody>, @AuditCtx() audit: AuditDetails) {
    if (a.branchIds.length && !a.branchIds.includes(b.branchId)) throw forbidden('branch_scope', 'Not your branch');
    const token = randomToken(32);
    const dev = await this.db.tenant(a.tenantId!, async (tx) => {
      if (!(await tx.branch.findUnique({ where: { id: b.branchId } }))) throw notFound('Branch');
      await tx.device.updateMany({ where: { branchId: b.branchId, isHub: true, revokedAt: null }, data: { isHub: false } });
      return tx.device.create({ data: { ...b, tenantId: a.tenantId!, isHub: true, deviceTokenHash: sha256(token) } });
    });
    Object.assign(audit, { branchId: b.branchId, objectType: 'device', objectId: dev.id, after: { ...b, isHub: true } });
    return { deviceId: dev.id, deviceToken: token, branchId: b.branchId };
  }

  @Public()
  @Post('sync/push')
  @HttpCode(200)
  async push(@Headers('x-device-token') token: string | undefined, @Body(zbody(PushBody)) b: z.infer<typeof PushBody>) {
    const dev = await this.sync.authenticateDevice(token);
    const results = await this.sync.push(dev, b.events);
    return { results };
  }

  @Public()
  @Get('sync/pull')
  async pull(@Headers('x-device-token') token: string | undefined, @Query(new ZodPipe(PullQuery)) q: z.infer<typeof PullQuery>) {
    const dev = await this.sync.authenticateDevice(token);
    return this.sync.pull(dev, BigInt(q.since));
  }

  @Public()
  @Get('sync/status')
  async status(@Headers('x-device-token') token: string | undefined) {
    return this.sync.status(await this.sync.authenticateDevice(token));
  }
}
