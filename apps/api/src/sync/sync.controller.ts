import { Body, Controller, Get, Headers, HttpCode, Post, Query } from '@nestjs/common';
import { ApiBody, ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { randomToken, sha256 } from '../common/crypto';
import { Audited, Public, RequirePermissions, RequiresFeature } from '../common/decorators';
import { badRequest, forbidden, notFound } from '../common/errors';
import { loadEnv } from '../config/env';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService } from '../db/db.service';
import { SyncService } from './sync.service';

const RegisterHubBody = z.object({
  branchId: z.string().uuid().optional(), // optional when the restaurant has exactly one branch (Standard / Professional)
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
  @ApiBody(apiBody(RegisterHubBody))
  async registerHub(@CurrentActor() a: Actor, @Body(zbody(RegisterHubBody)) b: z.infer<typeof RegisterHubBody>, @AuditCtx() audit: AuditDetails) {
    const token = randomToken(32);
    const { dev, branch } = await this.db.tenant(a.tenantId!, async (tx) => {
      const branches = await tx.branch.findMany({ where: b.branchId ? { id: b.branchId } : {} });
      if (!b.branchId && branches.length !== 1) throw badRequest('branch_required', 'This restaurant has several branches; pass branchId');
      const branch = branches[0];
      if (!branch) throw notFound('Branch');
      if (a.branchIds.length && !a.branchIds.includes(branch.id)) throw forbidden('branch_scope', 'Not your branch');
      await tx.device.updateMany({ where: { branchId: branch.id, isHub: true, revokedAt: null }, data: { isHub: false } });
      const dev = await tx.device.create({
        data: { name: b.name, platform: b.platform, branchId: branch.id, tenantId: a.tenantId!, isHub: true, deviceTokenHash: sha256(token) },
      });
      return { dev, branch };
    });
    Object.assign(audit, { branchId: branch.id, objectType: 'device', objectId: dev.id, after: { name: b.name, platform: b.platform, isHub: true } });
    // The public key is not secret: the hub needs it to verify license tokens offline.
    return { deviceId: dev.id, deviceToken: token, branchId: branch.id, branchCode: branch.code, licensePublicKey: loadEnv().LICENSE_PUBLIC_KEY };
  }

  @Public()
  @Post('sync/push')
  @HttpCode(200)
  @ApiBody(apiBody(PushBody))
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
