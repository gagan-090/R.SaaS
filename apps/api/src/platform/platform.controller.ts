import { Body, Controller, Get, Headers, HttpCode, Ip, Param, ParseUUIDPipe, Post, Patch, Query, Req } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Prisma } from '@prisma/client';
import { z } from 'zod';
import { AuthService } from '../auth/auth.service';
import { loadEnv } from '../config/env';
import type { Actor, AppRequest, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { AuditService } from '../common/audit.service';
import { randomToken, sha256 } from '../common/crypto';
import { Audited, RequirePermissions } from '../common/decorators';
import { badRequest, conflict, forbidden, notFound } from '../common/errors';
import { ALL_PLATFORM_PERMISSIONS } from '../common/permissions';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService, Tx } from '../db/db.service';
import { Mailer } from '../mail/mail.service';

const InviteBody = z.object({ email: z.string().email(), name: z.string().min(1).max(120), roleIds: z.array(z.string().uuid()).min(1) });
const RolesBody = z.object({ roleIds: z.array(z.string().uuid()) });
const ReasonBody = z.object({ reason: z.string().trim().min(3).max(500) });
const RoleBody = z.object({
  name: z.string().min(2).max(60),
  description: z.string().max(300).optional(),
  permissions: z.array(z.string()).min(1),
});
const AuditQuery = z.object({
  actorId: z.string().uuid().optional(),
  action: z.string().optional(),
  tenantId: z.string().uuid().optional(),
  from: z.coerce.date().optional(),
  to: z.coerce.date().optional(),
  page: z.coerce.number().int().min(1).default(1),
  pageSize: z.coerce.number().int().min(1).max(200).default(50),
});

/** Self-escalation guard: an admin may only hand out permissions they already hold. */
function assertSubset(actor: Actor, perms: string[]) {
  const extra = perms.filter((p) => !actor.permissions.has(p));
  if (extra.length) throw forbidden('escalation_denied', `You cannot grant permissions you do not hold: ${extra.join(', ')}`);
}

async function rolePerms(tx: Tx, roleIds: string[]) {
  const roles = await tx.platformRole.findMany({ where: { id: { in: roleIds } } });
  if (roles.length !== new Set(roleIds).size) throw badRequest('unknown_role', 'One or more roles do not exist');
  return { roles, perms: [...new Set(roles.flatMap((r) => r.permissions))] };
}

const adminView = (a: Prisma.PlatformAdminGetPayload<{ include: { roles: { include: { role: true } }; mfa: true } }>) => ({
  id: a.id, email: a.email, name: a.name, status: a.status, lastLoginAt: a.lastLoginAt,
  mfaEnrolled: !!a.mfa?.enrolledAt, roles: a.roles.map((r) => ({ id: r.role.id, name: r.role.name })),
});

@ApiTags('platform')
@ApiBearerAuth()
@Controller('platform')
export class PlatformController {
  constructor(private db: DbService, private auth: AuthService, private audit: AuditService, private mailer: Mailer) {}

  @RequirePermissions('platform.admin.read')
  @Get('admins')
  async listAdmins() {
    const admins = await this.db.platform((tx) =>
      tx.platformAdmin.findMany({ include: { roles: { include: { role: true } }, mfa: true }, orderBy: { createdAt: 'asc' } }),
    );
    return admins.map(adminView);
  }

  @RequirePermissions('platform.admin.invite')
  @Audited('platform.admin.invited')
  @Post('admins')
  @ApiBody(apiBody(InviteBody))
  async invite(@Body(zbody(InviteBody)) b: z.infer<typeof InviteBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const email = b.email.toLowerCase();
    const token = randomToken(32);
    const admin = await this.db.platform(async (tx) => {
      const { perms } = await rolePerms(tx, b.roleIds);
      assertSubset(actor, perms);
      if (await tx.platformAdmin.findUnique({ where: { email } })) throw conflict('duplicate_email', 'An admin with this email exists');
      if (await tx.user.findUnique({ where: { email } })) throw conflict('duplicate_email', 'Email belongs to a restaurant user');
      return tx.platformAdmin.create({
        data: {
          email, name: b.name, status: 'invited', invitedById: actor.id,
          inviteTokenHash: sha256(token), inviteExpiresAt: new Date(Date.now() + 72 * 3600_000),
          roles: { create: b.roleIds.map((roleId) => ({ roleId, assignedBy: actor.id })) },
        },
        include: { roles: { include: { role: true } }, mfa: true },
      });
    });
    await this.mailer.send({
      to: email,
      subject: 'You are invited to the Restaurant SaaS admin portal',
      text: `Accept your invite (valid 72 hours): ${loadEnv().PUBLIC_API_URL}/accept-invite?token=${token}`,
    });
    Object.assign(audit, { objectType: 'admin', objectId: admin.id, after: adminView(admin) });
    return adminView(admin);
  }

  @RequirePermissions('platform.admin.roles')
  @Audited('platform.admin.roles_changed')
  @Patch('admins/:id/roles')
  @ApiBody(apiBody(RolesBody))
  async setRoles(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(RolesBody)) b: z.infer<typeof RolesBody>,
    @CurrentActor() actor: Actor,
    @AuditCtx() audit: AuditDetails,
  ) {
    if (id === actor.id) throw forbidden('self_escalation', 'You cannot change your own roles');
    const { before, after } = await this.db.platform(async (tx) => {
      const target = await tx.platformAdmin.findUnique({ where: { id }, include: { roles: { include: { role: true } }, mfa: true } });
      if (!target) throw notFound('Admin');
      const { perms } = await rolePerms(tx, b.roleIds);
      assertSubset(actor, perms);
      // Nor may you edit someone who holds more authority than you.
      assertSubset(actor, target.roles.flatMap((r) => r.role.permissions));
      await tx.platformAdminRole.deleteMany({ where: { adminId: id } });
      await tx.platformAdminRole.createMany({ data: b.roleIds.map((roleId) => ({ adminId: id, roleId, assignedBy: actor.id })) });
      const updated = await tx.platformAdmin.findUniqueOrThrow({ where: { id }, include: { roles: { include: { role: true } }, mfa: true } });
      return { before: adminView(target), after: adminView(updated) };
    });
    Object.assign(audit, { objectType: 'admin', objectId: id, before: before.roles, after: after.roles });
    return after;
  }

  @RequirePermissions('platform.admin.deactivate')
  @Audited('platform.admin.deactivated')
  @Post('admins/:id/deactivate')
  @HttpCode(200)
  @ApiBody(apiBody(ReasonBody))
  async deactivate(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(ReasonBody)) b: z.infer<typeof ReasonBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    if (id === actor.id) throw forbidden('self_action', 'You cannot deactivate yourself');
    await this.db.platform(async (tx) => {
      const t = await tx.platformAdmin.findUnique({ where: { id }, include: { roles: { include: { role: true } } } });
      if (!t) throw notFound('Admin');
      assertSubset(actor, t.roles.flatMap((r) => r.role.permissions));
      await tx.platformAdmin.update({ where: { id }, data: { status: 'disabled' } });
      await tx.refreshToken.updateMany({ where: { subjectType: 'admin', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } });
    });
    Object.assign(audit, { objectType: 'admin', objectId: id, before: { status: 'active' }, after: { status: 'disabled' }, reason: b.reason });
    return { id, status: 'disabled' };
  }

  /** AC-03: needs platform.mfa.reset + a fresh step-up token; writes an audit event and a notification atomically. */
  @RequirePermissions('platform.mfa.reset')
  @Post('admins/:id/mfa/reset')
  @HttpCode(200)
  @ApiBody(apiBody(ReasonBody))
  async resetMfa(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(ReasonBody)) b: z.infer<typeof ReasonBody>,
    @Headers('x-step-up-token') stepUp: string | undefined,
    @CurrentActor() actor: Actor,
    @Req() req: AppRequest,
    @Ip() ip: string,
  ) {
    if (id === actor.id) throw forbidden('self_action', 'Use your recovery codes to regain access to your own account');
    this.auth.requireStepUp(actor, stepUp);
    const target = await this.db.platform(async (tx) => {
      const t = await tx.platformAdmin.findUnique({ where: { id }, include: { mfa: true } });
      if (!t) throw notFound('Admin');
      if (!t.mfa) throw conflict('mfa_not_enrolled', 'Admin has no MFA enrolment to reset');
      await tx.mFAEnrollment.update({
        where: { id: t.mfa.id },
        data: { totpSecretEncrypted: '', recoveryCodeHashes: [], enrolledAt: null, lastUsedStep: null, resetById: actor.id, resetAt: new Date() },
      });
      await tx.refreshToken.updateMany({ where: { subjectType: 'admin', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } });
      await tx.notification.create({
        data: { recipient: t.email, type: 'mfa_reset', payload: { adminId: id, resetBy: actor.id, reason: b.reason }, sentAt: new Date() },
      });
      await this.audit.record(
        { action: 'platform.admin.mfa_reset', objectType: 'admin', objectId: id, before: { mfaEnrolled: !!t.mfa.enrolledAt }, after: { mfaEnrolled: false }, reason: b.reason },
        actor, { ip, sessionId: actor.sessionId, deviceId: req.headers['x-device-id'] as string | undefined }, tx,
      );
      return t;
    });
    await this.mailer.send({
      to: target.email,
      subject: 'Your two-factor authentication was reset',
      text: `An administrator reset your MFA. Reason: ${b.reason}. You will be asked to enrol again at next sign-in. If this was unexpected, contact security.`,
    });
    return { id, mfaReset: true, notified: target.email };
  }

  @RequirePermissions('platform.admin.read')
  @Get('roles')
  roles() {
    return this.db.platform((tx) => tx.platformRole.findMany({ orderBy: { name: 'asc' } }));
  }

  @RequirePermissions('platform.admin.read')
  @Get('permissions')
  permissions() {
    return this.db.platform((tx) => tx.permission.findMany({ orderBy: { key: 'asc' } }));
  }

  @RequirePermissions('platform.admin.roles')
  @Audited('platform.role.created')
  @Post('roles')
  @ApiBody(apiBody(RoleBody))
  async createRole(@Body(zbody(RoleBody)) b: z.infer<typeof RoleBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const unknown = b.permissions.filter((p) => !(ALL_PLATFORM_PERMISSIONS as string[]).includes(p));
    if (unknown.length) throw badRequest('unknown_permission', `Unknown platform permissions: ${unknown.join(', ')}`);
    assertSubset(actor, b.permissions);
    const role = await this.db.platform(async (tx) => {
      if (await tx.platformRole.findUnique({ where: { name: b.name } })) throw conflict('duplicate_role', 'Role name exists');
      return tx.platformRole.create({ data: { name: b.name, description: b.description, permissions: b.permissions } });
    });
    Object.assign(audit, { objectType: 'platform_role', objectId: role.id, after: role });
    return role;
  }

  @RequirePermissions('platform.audit.read')
  @Get('audit')
  async auditLog(@Query(new ZodPipe(AuditQuery)) q: z.infer<typeof AuditQuery>) {
    const where: Prisma.AuditEventWhereInput = {
      actorId: q.actorId, tenantId: q.tenantId,
      action: q.action ? { contains: q.action } : undefined,
      at: q.from || q.to ? { gte: q.from, lte: q.to } : undefined,
    };
    return this.db.platform(async (tx) => {
      const [items, total] = await Promise.all([
        tx.auditEvent.findMany({ where, orderBy: { at: 'desc' }, skip: (q.page - 1) * q.pageSize, take: q.pageSize }),
        tx.auditEvent.count({ where }),
      ]);
      return { items, total, page: q.page, pageSize: q.pageSize };
    });
  }
}
