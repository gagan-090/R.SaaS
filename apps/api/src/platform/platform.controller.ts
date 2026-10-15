import { Body, Controller, Get, Headers, HttpCode, Ip, Param, ParseUUIDPipe, Post, Patch, Query, Req } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Prisma } from '@prisma/client';
import { z } from 'zod';
import { AuthService, hashPassword } from '../auth/auth.service';
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
const CreateAdminBody = z.object({
  email: z.string().trim().toLowerCase().email(),
  name: z.string().trim().min(1).max(120),
  password: z.string().min(12).max(256),
  roleIds: z.array(z.string().uuid()).min(1).optional(),
});
const ActivateAdminBody = z.object({ password: z.string().min(12).max(256) });
const MfaPolicyBody = z.object({ enabled: z.boolean(), reason: z.string().trim().min(3).max(500) });
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
  category: z.string().optional(), // account_lifecycle, authentication, account_creation, account_deletion, mfa_reset, auth_success, auth_failure
  tenantId: z.string().optional(),
  q: z.string().optional(),
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
  mfaEnabled: a.mfaEnabled, mfaEnrolled: !!a.mfa?.enrolledAt, roles: a.roles.map((r) => ({ id: r.role.id, name: r.role.name })),
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

  /** Creates a usable account without email delivery. The three-field form defaults to Onboarding Admin. */
  @RequirePermissions('platform.admin.invite')
  @Audited('platform.admin.created')
  @Post('admins/create')
  @ApiBody(apiBody(CreateAdminBody))
  async createAdmin(@Body(zbody(CreateAdminBody)) b: z.infer<typeof CreateAdminBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const passwordHash = await hashPassword(b.password);
    let admin;
    try {
      admin = await this.db.platform(async (tx) => {
        const defaultRole = !b.roleIds ? await tx.platformRole.findUnique({ where: { name: 'Onboarding Admin' } }) : null;
        if (!b.roleIds && !defaultRole) throw badRequest('unknown_role', 'The default Onboarding Admin role is missing');
        const roleIds = [...new Set(b.roleIds ?? [defaultRole!.id])];
        const { perms } = await rolePerms(tx, roleIds);
        assertSubset(actor, perms);
        if (await tx.platformAdmin.findUnique({ where: { email: b.email } })) {
          throw conflict('duplicate_email', 'An admin with this email already exists. For an invited admin, use Set password & activate.');
        }
        if (await tx.user.findUnique({ where: { email: b.email } })) throw conflict('duplicate_email', 'Email belongs to a restaurant user');
        return tx.platformAdmin.create({
          data: {
            email: b.email, name: b.name, passwordHash, status: 'active', invitedById: actor.id,
            roles: { create: roleIds.map((roleId) => ({ roleId, assignedBy: actor.id })) },
          },
          include: { roles: { include: { role: true } }, mfa: true },
        });
      });
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') throw conflict('duplicate_email', 'An admin with this email already exists');
      throw e;
    }
    const view = adminView(admin);
    Object.assign(audit, { objectType: 'admin', objectId: admin.id, after: view });
    return view;
  }

  /** Finishes only a pending invitation; never resets an active admin's password or MFA. */
  @RequirePermissions('platform.admin.invite')
  @Audited('platform.admin.activated')
  @Post('admins/:id/activate')
  @HttpCode(200)
  @ApiBody(apiBody(ActivateAdminBody))
  async activateAdmin(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(ActivateAdminBody)) b: z.infer<typeof ActivateAdminBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const passwordHash = await hashPassword(b.password);
    const { before, after } = await this.db.platform(async (tx) => {
      const target = await tx.platformAdmin.findUnique({ where: { id }, include: { roles: { include: { role: true } }, mfa: true } });
      if (!target) throw notFound('Admin');
      assertSubset(actor, target.roles.flatMap((r) => r.role.permissions));
      if (target.status !== 'invited') throw conflict('not_invited', 'Only invited admins can be activated here');
      const changed = await tx.platformAdmin.updateMany({
        where: { id, status: 'invited' },
        data: { passwordHash, status: 'active', inviteTokenHash: null, inviteExpiresAt: null, failedLoginCount: 0, lockedUntil: null },
      });
      if (changed.count !== 1) throw conflict('not_invited', 'This invitation has already been activated');
      await tx.refreshToken.updateMany({ where: { subjectType: 'admin', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } });
      const updated = await tx.platformAdmin.findUniqueOrThrow({ where: { id }, include: { roles: { include: { role: true } }, mfa: true } });
      return { before: adminView(target), after: adminView(updated) };
    });
    Object.assign(audit, { objectType: 'admin', objectId: id, before, after, reason: 'Admin completed a pending invitation with a password directly' });
    return after;
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

  /** Housekeeping: Removes an admin user, frees the email for future registration, revokes sessions, and records audit trail. */
  @RequirePermissions('platform.admin.deactivate')
  @Audited('platform.admin.deleted')
  @Post('admins/:id/delete')
  @HttpCode(200)
  @ApiBody(apiBody(ReasonBody))
  async deleteAdmin(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(ReasonBody)) b: z.infer<typeof ReasonBody>,
    @CurrentActor() actor: Actor,
    @AuditCtx() audit: AuditDetails,
  ) {
    if (id === actor.id) throw forbidden('self_action', 'You cannot remove your own admin account');
    const { before, after } = await this.db.platform(async (tx) => {
      const t = await tx.platformAdmin.findUnique({ where: { id }, include: { roles: { include: { role: true } } } });
      if (!t) throw notFound('Admin');
      // Protect the last Super Admin
      const isSuper = t.roles.some((r) => r.role.name === 'Super Admin');
      if (isSuper) {
        const remainingSuperAdmins = await tx.platformAdminRole.count({
          where: { role: { name: 'Super Admin' }, admin: { status: { in: ['active', 'invited'] }, id: { not: id } } },
        });
        if (remainingSuperAdmins === 0) throw conflict('last_super_admin', 'Cannot remove the last active Super Admin account');
      }
      assertSubset(actor, t.roles.flatMap((r) => r.role.permissions));

      const freedEmail = `deleted_${Date.now()}_${t.email}`;
      const updated = await tx.platformAdmin.update({
        where: { id },
        data: {
          status: 'deleted',
          email: freedEmail,
          deletedAt: new Date(),
        },
        include: { roles: { include: { role: true } }, mfa: true },
      });
      await tx.refreshToken.updateMany({ where: { subjectType: 'admin', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } });
      return { before: t, after: updated };
    });
    Object.assign(audit, {
      objectType: 'admin',
      objectId: id,
      before: { email: before.email, status: before.status },
      after: { email: after.email, status: after.status, deletedAt: after.deletedAt },
      reason: b.reason,
    });
    return { id, status: 'deleted', message: `Admin ${before.name} removed successfully` };
  }

  /** AC-03: needs platform.mfa.reset + a fresh step-up token; writes an audit event and a notification atomically. */
  @RequirePermissions('platform.mfa.reset')
  @Post('admins/:id/mfa/policy')
  @HttpCode(200)
  @ApiBody(apiBody(MfaPolicyBody))
  async setMfaPolicy(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(MfaPolicyBody)) b: z.infer<typeof MfaPolicyBody>,
    @CurrentActor() actor: Actor,
    @Headers('x-step-up-token') stepUp: string | undefined,
    @Req() req: AppRequest,
  ) {
    if (actor.type !== 'admin' || !actor.roles.includes('Super Admin')) throw forbidden('super_admin_only', 'Only Super Admins can turn MFA on or off');
    this.auth.requireStepUp(actor, stepUp);
    return this.db.platform(async (tx) => {
      const target = await tx.platformAdmin.findUnique({ where: { id }, include: { roles: { include: { role: true } }, mfa: true } });
      if (!target) throw notFound('Admin');
      if (target.mfaEnabled === b.enabled) return { ...adminView(target), sessionsRevoked: false };
      const updated = await tx.platformAdmin.update({ where: { id }, data: { mfaEnabled: b.enabled } });
      await tx.refreshToken.updateMany({ where: { subjectType: 'admin', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.audit.record({ action: 'platform.admin.mfa_policy_changed', objectType: 'admin', objectId: id,
        before: { mfaEnabled: target.mfaEnabled }, after: { mfaEnabled: updated.mfaEnabled }, reason: b.reason }, actor,
        { ip: req.ip, sessionId: actor.sessionId, requestId: req.requestId }, tx);
      return { ...adminView({ ...target, ...updated }), sessionsRevoked: true };
    });
  }

  /** Reset an authenticator while preserving the account's MFA policy. */
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

  /** Needs attention work queue: overdue payments, upcoming renewals, suspended > 3m, archived > 1y, awaiting verification. */
  @RequirePermissions('platform.restaurant.read')
  @Get('attention')
  async attention() {
    const now = new Date();
    const in30 = new Date(now.getTime() + 30 * 86_400_000);
    const threeMonthsAgo = new Date(now.getTime() - 90 * 86_400_000);
    const oneYearAgo = new Date(now.getTime() - 365 * 86_400_000);

    return this.db.platform(async (tx) => {
      // 1. Overdue licenses (active status, endsAt <= now) & upcoming licenses (active, endsAt > now and endsAt <= in30)
      const activeTenantsWithLicenses = await tx.restaurantTenant.findMany({
        where: { status: 'active' },
        include: {
          licenses: { where: { status: 'active' }, include: { plan: true }, orderBy: { endsAt: 'desc' }, take: 1 },
        },
      });

      const overdueLicenses: Array<{ id: string; name: string; code: string; plan: string; endsAt: Date; daysOverdue: number }> = [];
      const upcomingLicenses: Array<{ id: string; name: string; code: string; plan: string; endsAt: Date; daysLeft: number }> = [];

      for (const t of activeTenantsWithLicenses) {
        const lic = t.licenses[0];
        if (!lic) continue;
        if (lic.endsAt <= now) {
          const daysOverdue = Math.floor((now.getTime() - lic.endsAt.getTime()) / 86_400_000);
          overdueLicenses.push({ id: t.id, name: t.name, code: t.code, plan: lic.plan.name, endsAt: lic.endsAt, daysOverdue });
        } else if (lic.endsAt <= in30) {
          const daysLeft = Math.ceil((lic.endsAt.getTime() - now.getTime()) / 86_400_000);
          upcomingLicenses.push({ id: t.id, name: t.name, code: t.code, plan: lic.plan.name, endsAt: lic.endsAt, daysLeft });
        }
      }

      // 2. Suspended for more than 3 months
      const suspendedTenants = await tx.restaurantTenant.findMany({
        where: {
          status: 'suspended',
          OR: [
            { statusChangedAt: { lte: threeMonthsAgo } },
            { statusChangedAt: null, updatedAt: { lte: threeMonthsAgo } },
          ],
        },
        orderBy: { statusChangedAt: 'asc' },
      });

      // 3. Archived for more than 1 year
      const archivedTenants = await tx.restaurantTenant.findMany({
        where: {
          status: 'archived',
          OR: [
            { statusChangedAt: { lte: oneYearAgo } },
            { statusChangedAt: null, updatedAt: { lte: oneYearAgo } },
          ],
        },
        orderBy: { statusChangedAt: 'asc' },
      });

      // 4. Registrations awaiting verification
      const awaitingRegistrations = await tx.restaurantRegistration.findMany({
        where: { verifiedAt: null, cancelledAt: null, expiresAt: { gt: now } },
        orderBy: { createdAt: 'desc' },
      });

      return {
        counts: {
          overdue: overdueLicenses.length,
          upcoming: upcomingLicenses.length,
          suspended3m: suspendedTenants.length,
          archived1y: archivedTenants.length,
          awaiting: awaitingRegistrations.length,
        },
        overdueLicenses,
        upcomingLicenses,
        suspendedTenants: suspendedTenants.map((t) => ({
          id: t.id,
          name: t.name,
          code: t.code,
          suspendedAt: t.statusChangedAt ?? t.updatedAt,
          daysSuspended: Math.floor((now.getTime() - (t.statusChangedAt ?? t.updatedAt).getTime()) / 86_400_000),
          reason: t.statusReason,
        })),
        archivedTenants: archivedTenants.map((t) => ({
          id: t.id,
          name: t.name,
          code: t.code,
          archivedAt: t.statusChangedAt ?? t.updatedAt,
          daysArchived: Math.floor((now.getTime() - (t.statusChangedAt ?? t.updatedAt).getTime()) / 86_400_000),
          reason: t.statusReason,
        })),
        awaitingRegistrations: awaitingRegistrations.map((r) => ({
          id: r.id,
          restaurantName: r.restaurantName,
          ownerEmail: r.ownerEmail,
          ownerName: r.ownerName,
          createdAt: r.createdAt,
          expiresAt: r.expiresAt,
        })),
      };
    });
  }

  @RequirePermissions('platform.audit.read')
  @Get('audit')
  async auditLog(@Query(new ZodPipe(AuditQuery)) q: z.infer<typeof AuditQuery>) {
    // 1.5 year retention window (548 days)
    const minRetention = new Date(Date.now() - 548 * 86_400_000);
    const fromDate = q.from ? (q.from < minRetention ? minRetention : q.from) : minRetention;
    const toDate = q.to;

    // Granular category resolution
    let actionFilter: Prisma.StringFilter | Prisma.Enumerable<Prisma.AuditEventWhereInput> | undefined = undefined;
    if (q.action) {
      actionFilter = { contains: q.action };
    } else if (q.category) {
      switch (q.category) {
        case 'account_lifecycle':
          actionFilter = {
            in: [
              'platform.admin.created', 'platform.admin.invited', 'platform.admin.activated',
              'platform.admin.deactivated', 'platform.admin.deleted', 'platform.admin.mfa_reset',
              'platform.admin.mfa_policy_changed', 'restaurant.created', 'restaurant.archived',
              'restaurant.restored', 'restaurant.deleted', 'user.created', 'user.deleted', 'staff.created', 'staff.deleted'
            ],
          };
          break;
        case 'account_creation':
          actionFilter = {
            in: ['platform.admin.created', 'platform.admin.invited', 'platform.admin.activated', 'restaurant.created', 'user.created', 'staff.created'],
          };
          break;
        case 'account_deletion':
          actionFilter = {
            in: ['platform.admin.deleted', 'user.deleted', 'staff.deleted', 'restaurant.deleted'],
          };
          break;
        case 'mfa_reset':
          actionFilter = {
            in: ['platform.admin.mfa_reset', 'platform.admin.mfa_policy_changed', 'auth.mfa_reset'],
          };
          break;
        case 'authentication':
          actionFilter = {
            in: [
              'auth.login', 'auth.login_recovery_code', 'auth.pin_login', 'auth.logout',
              'auth.step_up', 'auth.login_failed', 'auth.mfa_failed', 'auth.step_up_failed',
              'auth.refresh_reuse_detected',
            ],
          };
          break;
        case 'auth_success':
          actionFilter = {
            in: ['auth.login', 'auth.login_recovery_code', 'auth.pin_login', 'auth.step_up'],
          };
          break;
        case 'auth_failure':
          actionFilter = {
            in: ['auth.login_failed', 'auth.mfa_failed', 'auth.step_up_failed', 'auth.refresh_reuse_detected'],
          };
          break;
        case 'restaurant_lifecycle':
          actionFilter = {
            in: ['restaurant.registered', 'restaurant.created', 'restaurant.status_changed', 'restaurant.archived', 'restaurant.restored', 'restaurant.deleted'],
          };
          break;
      }
    }

    return this.db.platform(async (tx) => {
      let resolvedTenantId = q.tenantId;
      if (q.tenantId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(q.tenantId)) {
        // user passed restaurant code or name instead of uuid
        const found = await tx.restaurantTenant.findFirst({
          where: { OR: [{ code: { equals: q.tenantId, mode: 'insensitive' } }, { name: { contains: q.tenantId, mode: 'insensitive' } }] },
          select: { id: true },
        });
        resolvedTenantId = found?.id ?? '00000000-0000-0000-0000-000000000000';
      }

      const where: Prisma.AuditEventWhereInput = {
        actorId: q.actorId,
        tenantId: resolvedTenantId,
        ...(actionFilter ? { action: actionFilter as never } : {}),
        at: { gte: fromDate, ...(toDate ? { lte: toDate } : {}) },
        ...(q.q
          ? {
              OR: [
                { action: { contains: q.q, mode: 'insensitive' } },
                { reason: { contains: q.q, mode: 'insensitive' } },
                { actorName: { contains: q.q, mode: 'insensitive' } },
                { ip: { contains: q.q, mode: 'insensitive' } },
              ],
            }
          : {}),
      };

      const [items, total] = await Promise.all([
        tx.auditEvent.findMany({ where, orderBy: { at: 'desc' }, skip: (q.page - 1) * q.pageSize, take: q.pageSize }),
        tx.auditEvent.count({ where }),
      ]);
      // who did it, in words: name + role for staff, name for platform admins, restaurant name for the tenant
      const userIds = [...new Set(items.filter((i) => i.actorType === 'user' && i.actorId).map((i) => i.actorId!))];
      const adminIds = [...new Set(items.filter((i) => i.actorType === 'admin' && i.actorId).map((i) => i.actorId!))];
      const tenantIds = [...new Set(items.filter((i) => i.tenantId).map((i) => i.tenantId!))];
      const [users, admins, tenants] = await Promise.all([
        tx.user.findMany({ where: { id: { in: userIds } }, select: { id: true, name: true, email: true, roles: { select: { role: true } } } }),
        tx.platformAdmin.findMany({ where: { id: { in: adminIds } }, select: { id: true, name: true, email: true } }),
        tx.restaurantTenant.findMany({ where: { id: { in: tenantIds } }, select: { id: true, name: true } }),
      ]);
      const who = new Map<string, { name: string; detail: string | null }>([
        ...users.map((u) => [u.id, { name: u.name.split(' (')[0], detail: u.roles[0]?.role ?? null }] as const),
        ...admins.map((a) => [a.id, { name: a.name, detail: 'Platform admin' }] as const),
      ]);
      const tenantName = new Map(tenants.map((t) => [t.id, t.name]));
      return {
        retentionMonths: 18,
        retentionDays: 548,
        items: items.map((i) => ({
          ...i,
          actorName: i.actorName ?? (i.actorId ? (who.get(i.actorId)?.name ?? null) : null),
          actorRole: i.actorRole ?? (i.actorId ? (who.get(i.actorId)?.detail ?? null) : null),
          tenantName: i.tenantId ? (tenantName.get(i.tenantId) ?? null) : null,
        })),
        total, page: q.page, pageSize: q.pageSize,
      };
    });
  }
}
