import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { hashPassword } from '../auth/auth.service';
import { randomToken, sha256 } from '../common/crypto';
import { Audited, RequirePermissions, RequiresFeature } from '../common/decorators';
import { badRequest, conflict, forbidden, notFound } from '../common/errors';
import {
  EXTENDED_ROLES, RESTAURANT_PERMISSIONS, ROLE_PERMISSIONS, limitToPlan, type RestaurantRoleName,
} from '../common/permissions';
import { apiBody, zbody } from '../common/validation';
import { loadEnv } from '../config/env';
import { DbService, Tx } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';
import { Mailer } from '../mail/mail.service';
import { staffPinEmail } from '../mail/templates';
import { pinProblem } from './pin-policy';

/** Roles an owner / Restaurant Admin can give from the console. Owners are created at onboarding; ownership is never transferred here. */
const STAFF_ROLES = ['it_admin', 'cashier', 'waiter', 'chef', 'auditor', 'custom'] as const;
const PIN_LINK_HOURS = 72;

const Pin = z.string().superRefine((p, ctx) => {
  const problem = pinProblem(p);
  if (problem) ctx.addIssue({ code: 'custom', message: problem });
});

export const StaffBody = z
  .object({
    name: z.string().trim().min(1).max(80),
    email: z.string().trim().toLowerCase().email(),
    phone: z.string().trim().max(20).optional(),
    role: z.enum(STAFF_ROLES),
    customRoleId: z.string().uuid().optional(),
    pin: Pin.optional(),
    sendInvite: z.boolean().default(false), // email a one-time link so the employee chooses their own PIN
    status: z.enum(['active', 'disabled']).default('active'),
    webAccess: z.boolean().default(false),
    canDiscount: z.boolean().default(false), // cashier extra permission
    password: z.string().min(8).max(200).optional(), // optional console password (admins / auditors)
  })
  .refine((b) => !!b.pin || b.sendInvite, { message: 'Set a PIN now or send an invite so they choose one', path: ['pin'] })
  .refine((b) => b.role !== 'custom' || !!b.customRoleId, { message: 'Choose the custom role', path: ['customRoleId'] });

const StaffPatch = z.object({
  name: z.string().trim().min(1).max(80).optional(),
  email: z.string().trim().toLowerCase().email().optional(),
  role: z.enum(STAFF_ROLES).optional(),
  customRoleId: z.string().uuid().optional(),
  pin: Pin.optional(),
  phone: z.string().trim().max(20).nullable().optional(),
  status: z.enum(['active', 'disabled']).optional(),
  webAccess: z.boolean().optional(),
  canDiscount: z.boolean().optional(),
});

const RoleBody = z.object({
  name: z.string().trim().min(2).max(40),
  description: z.string().trim().max(200).optional(),
  permissions: z.array(z.string()).min(1).refine((ps) => ps.every((p) => p in RESTAURANT_PERMISSIONS), 'Unknown permission'),
});

type Ent = Awaited<ReturnType<LicenseService['entitlement']>>;

/**
 * Employees and roles of the signed-in restaurant. Every query runs under the tenant's RLS context, so another
 * restaurant's people can never be read or changed. Hubs receive changes on their next pull (about a minute).
 */
@ApiTags('staff')
@ApiBearerAuth()
@Controller()
export class StaffController {
  constructor(private db: DbService, private licenses: LicenseService, private mailer: Mailer) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  private isOwner = (a: Actor) => a.roles.includes('owner');

  /**
   * What an actor may hand out. Owners: any role their plan allows. Restaurant Admins: the standard staff roles
   * (cashier, waiter, chef, auditor) — never another admin or the owner — and only custom roles / extra grants made of
   * permissions they hold themselves.
   */
  private async assertCanAssign(tx: Tx, a: Actor, ent: Ent, role: RestaurantRoleName, customRoleId: string | undefined, canDiscount: boolean) {
    const owner = this.isOwner(a);
    if (role === 'owner') throw forbidden('owner_protected', 'Ownership cannot be assigned here');
    if (role === 'it_admin' && !owner) throw forbidden('owner_only', 'Only the owner can add or change Restaurant Admins');
    if (EXTENDED_ROLES.includes(role) && !ent.features.includes('roles.extended')) {
      throw forbidden('feature_not_in_plan', `The ${role === 'it_admin' ? 'Restaurant Admin' : role} role needs a plan with extended roles`);
    }
    if (canDiscount && role === 'cashier' && !owner && !a.permissions.has('discount.apply')) {
      throw forbidden('beyond_authority', 'You cannot grant discounts because you do not have that permission');
    }
    if (role !== 'custom') return null;
    if (!ent.features.includes('roles.custom')) throw forbidden('feature_not_in_plan', 'Custom roles are not in your plan');
    const cr = customRoleId ? await tx.customRole.findUnique({ where: { id: customRoleId } }) : null;
    if (!cr || cr.deleted) throw notFound('Custom role');
    const beyond = cr.permissions.filter((p) => !a.permissions.has(p));
    if (!owner && beyond.length) throw forbidden('beyond_authority', `This role includes permissions you do not have: ${beyond.join(', ')}`);
    return cr;
  }

  private async assertUnderLimit(tx: Tx, ent: Ent, exceptUserId?: string) {
    const limit = ent.limits.staffPerBranch;
    if (limit === null || limit === undefined) return;
    const active = await tx.user.count({ where: { status: 'active', roles: { none: { role: 'owner' } }, ...(exceptUserId ? { id: { not: exceptUserId } } : {}) } });
    if (active >= limit) throw forbidden('employee_limit', `Your plan allows ${limit} active employees. Turn someone off or ask for a bigger plan.`);
  }

  /** No active plan (never issued, revoked or expired to read-only) means no new or re-activated employees. */
  private assertPlanActive(ent: Ent) {
    if (ent.state === 'none') throw forbidden('no_active_plan', 'Your restaurant has no active plan, so employees cannot be added or changed. Ask House Plating to issue a plan.');
    if (ent.readOnly) throw forbidden('license_read_only', `Your plan is ${ent.state.replace(/_/g, ' ')}, so employees cannot be added or changed. Renew or contact House Plating.`);
  }

  private async emailTaken(email: string, exceptUserId?: string) {
    const [u, admin] = await this.db.platform((p) => Promise.all([p.user.findUnique({ where: { email } }), p.platformAdmin.findUnique({ where: { email } })]));
    return !!admin || (!!u && u.id !== exceptUserId);
  }

  /** Creates a one-time PIN link and emails it. When email fails the link is returned so the owner can pass it on. */
  private async sendPinLink(tx: Tx, a: Actor, user: { id: string; name: string; email: string | null }, purpose: 'invite' | 'reset') {
    if (!user.email) throw badRequest('no_email', 'Add an email address first');
    const token = randomToken(32);
    await tx.pinToken.updateMany({ where: { userId: user.id, usedAt: null }, data: { usedAt: new Date() } }); // older links stop working
    await tx.pinToken.create({
      data: { tenantId: a.tenantId!, userId: user.id, tokenHash: sha256(token), purpose, createdBy: a.id, expiresAt: new Date(Date.now() + PIN_LINK_HOURS * 3600_000) },
    });
    const tenant = await tx.restaurantTenant.findUniqueOrThrow({ where: { id: a.tenantId } });
    const url = `${loadEnv().CONSOLE_URL.replace(/\/$/, '')}/#/set-pin?token=${token}`;
    try {
      await this.mailer.send({ to: user.email, ...staffPinEmail({ name: user.name, restaurantName: tenant.name, url, purpose }) });
      return { emailSent: true as const };
    } catch (e) {
      return { emailSent: false as const, emailError: e instanceof Error ? e.message : 'Email could not be sent', url };
    }
  }

  // ---------------------------------------------------------------- employees

  @RequirePermissions('staff.read')
  @Get('staff')
  async staff(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) =>
      (await tx.user.findMany({ include: { roles: { include: { customRole: true } } }, orderBy: [{ status: 'asc' }, { name: 'asc' }] })).map((u) => {
        const r = u.roles[0];
        return {
          id: u.id, name: u.name, email: u.email, phone: u.phone, status: u.status, hasPin: !!u.pinHash, pinSetAt: u.pinSetAt,
          webAccess: u.webAccess, locked: !!u.lockedUntil && u.lockedUntil > new Date(), createdAt: u.createdAt,
          role: r?.role ?? null, customRoleId: r?.customRoleId ?? null, customRoleName: r?.customRole?.name ?? null,
          canDiscount: u.roles.some((x) => x.extraPermissions.includes('discount.apply')),
        };
      }),
    );
  }

  /** Plan facts the employee form needs: limit, staff portal and custom roles availability. */
  @RequirePermissions('staff.read')
  @Get('staff/limits')
  async limits(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const ent = await this.licenses.entitlement(tx, a.tenantId!);
      const active = await tx.user.count({ where: { status: 'active', roles: { none: { role: 'owner' } } } });
      return {
        employeeLimit: ent.limits.staffPerBranch ?? null, activeEmployees: active,
        staffPortal: ent.features.includes('staff_portal'), customRoles: ent.features.includes('roles.custom'),
        extendedRoles: ent.features.includes('roles.extended'), planActive: ent.state !== 'none' && !ent.readOnly,
      };
    });
  }

  @RequirePermissions('staff.manage')
  @Audited('staff.created')
  @Post('staff')
  @ApiBody(apiBody(StaffBody))
  async create(@CurrentActor() a: Actor, @Body(zbody(StaffBody)) b: z.infer<typeof StaffBody>, @AuditCtx() audit: AuditDetails) {
    if (await this.emailTaken(b.email)) throw conflict('email_taken', 'That email is already used by another account');
    const [pinHash, passwordHash] = await Promise.all([b.pin ? hashPassword(b.pin) : null, b.password ? hashPassword(b.password) : null]);
    const r = await this.t(a, async (tx) => {
      const ent = await this.licenses.entitlement(tx, a.tenantId!);
      this.assertPlanActive(ent);
      const cr = await this.assertCanAssign(tx, a, ent, b.role, b.customRoleId, b.canDiscount);
      if (b.status === 'active') await this.assertUnderLimit(tx, ent);
      if (b.webAccess && !ent.features.includes('staff_portal')) throw forbidden('feature_not_in_plan', 'Web portal access for employees is not in your plan');
      const u = await tx.user.create({
        data: {
          tenantId: a.tenantId!, name: b.name, email: b.email, phone: b.phone, status: b.status, webAccess: b.webAccess,
          passwordHash, pinHash, pinSetAt: pinHash ? new Date() : null,
          roles: {
            create: {
              tenantId: a.tenantId!, role: b.role, branchIds: [], customRoleId: cr?.id ?? null,
              extraPermissions: b.role === 'cashier' && b.canDiscount ? ['discount.apply'] : [],
            },
          },
        },
      });
      const invite = b.sendInvite ? await this.sendPinLink(tx, a, u, 'invite') : null;
      return { u, invite, roleName: cr?.name };
    });
    // never audit the PIN or password
    Object.assign(audit, {
      objectType: 'user', objectId: r.u.id,
      after: { name: r.u.name, email: r.u.email, role: b.role, customRole: r.roleName, status: b.status, webAccess: b.webAccess, canDiscount: b.canDiscount, pinSet: !!b.pin, invited: b.sendInvite },
    });
    return { id: r.u.id, name: r.u.name, role: b.role, status: r.u.status, webAccess: r.u.webAccess, invite: r.invite };
  }

  @RequirePermissions('staff.manage')
  @Audited('staff.updated')
  @Patch('staff/:id')
  @ApiBody(apiBody(StaffPatch))
  async update(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(StaffPatch)) b: z.infer<typeof StaffPatch>, @AuditCtx() audit: AuditDetails) {
    if (Object.keys(b).length === 0) throw badRequest('empty_patch', 'Nothing to update');
    if (b.email && (await this.emailTaken(b.email, id))) throw conflict('email_taken', 'That email is already used by another account');
    const pinHash = b.pin ? await hashPassword(b.pin) : undefined;
    const r = await this.t(a, async (tx) => {
      const before = await tx.user.findUnique({ where: { id }, include: { roles: { include: { customRole: true } } } });
      if (!before) throw notFound('Employee');
      const role = before.roles[0];
      const ent = await this.licenses.entitlement(tx, a.tenantId!);
      // turning someone off is always allowed (a leaver must lose access even without a plan)
      if (!(Object.keys(b).length === 1 && b.status === 'disabled')) this.assertPlanActive(ent);
      if (role?.role === 'owner' && (b.role || b.status === 'disabled' || b.webAccess === false)) {
        throw forbidden('owner_protected', 'The owner account cannot be demoted or turned off here');
      }
      if (id === a.id && b.status === 'disabled') throw badRequest('self_disable', 'You cannot turn off your own account');
      if (role?.role === 'it_admin' && !this.isOwner(a)) throw forbidden('owner_only', 'Only the owner can change Restaurant Admins');
      // editing someone whose current role you could not assign is refused too
      if (role && role.role !== 'owner') {
        await this.assertCanAssign(tx, a, ent, (b.role ?? role.role) as RestaurantRoleName, b.customRoleId ?? role.customRoleId ?? undefined,
          b.canDiscount ?? role.extraPermissions.includes('discount.apply'));
      }
      if (b.status === 'active' && before.status !== 'active') await this.assertUnderLimit(tx, ent, id);
      if (b.webAccess && !ent.features.includes('staff_portal')) throw forbidden('feature_not_in_plan', 'Web portal access for employees is not in your plan');
      const after = await tx.user.update({
        where: { id },
        data: {
          name: b.name, email: b.email, phone: b.phone, status: b.status, webAccess: b.webAccess,
          ...(pinHash ? { pinHash, pinSetAt: new Date(), failedLoginCount: 0, lockedUntil: null } : {}),
        },
      });
      if (role && role.role !== 'owner' && (b.role || b.customRoleId || b.canDiscount !== undefined)) {
        const nextRole = b.role ?? role.role;
        const canDiscount = b.canDiscount ?? role.extraPermissions.includes('discount.apply');
        await tx.userRoleAssignment.update({
          where: { id: role.id },
          data: {
            role: nextRole, customRoleId: nextRole === 'custom' ? (b.customRoleId ?? role.customRoleId) : null,
            extraPermissions: nextRole === 'cashier' && canDiscount ? ['discount.apply'] : [],
          },
        });
      }
      if (b.status === 'disabled' || b.webAccess === false) {
        // signed out of the web everywhere at once; hubs drop them on the next config pull
        await this.db.platform((p) => p.refreshToken.updateMany({ where: { subjectType: 'user', subjectId: id, revokedAt: null }, data: { revokedAt: new Date() } }));
      }
      const pick = (u: typeof after) => ({ name: u.name, email: u.email, phone: u.phone, status: u.status, webAccess: u.webAccess });
      return {
        before: { ...pick(before), role: role?.role, customRole: role?.customRole?.name ?? null },
        after: { ...pick(after), role: b.role ?? role?.role, pinChanged: !!pinHash },
      };
    });
    Object.assign(audit, { objectType: 'user', objectId: id, before: r.before, after: r.after });
    return { id, ...r.after };
  }

  /** Emails a one-time link so the employee chooses a new PIN themselves (the current PIN keeps working until then). */
  @RequirePermissions('staff.manage')
  @Audited('staff.pin_link_sent')
  @Post('staff/:id/pin-link')
  @HttpCode(200)
  async pinLink(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const u = await tx.user.findUnique({ where: { id }, include: { roles: true } });
      if (!u) throw notFound('Employee');
      if (u.roles.some((x) => x.role === 'it_admin') && !this.isOwner(a)) throw forbidden('owner_only', 'Only the owner can reset a Restaurant Admin');
      if (u.status !== 'active') throw badRequest('inactive', 'Turn the employee on first');
      return { purpose: u.pinHash ? ('reset' as const) : ('invite' as const), ...(await this.sendPinLink(tx, a, u, u.pinHash ? 'reset' : 'invite')) };
    });
    Object.assign(audit, { objectType: 'user', objectId: id, after: { purpose: r.purpose, emailSent: r.emailSent } });
    return r;
  }

  /** Clears a temporary lockout after too many wrong PINs or passwords. */
  @RequirePermissions('staff.manage')
  @Audited('staff.unlocked')
  @Post('staff/:id/unlock')
  @HttpCode(200)
  async unlock(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    await this.t(a, async (tx) => {
      const u = await tx.user.findUnique({ where: { id } });
      if (!u) throw notFound('Employee');
      await tx.user.update({ where: { id }, data: { failedLoginCount: 0, lockedUntil: null } });
    });
    Object.assign(audit, { objectType: 'user', objectId: id });
    return { id, locked: false };
  }

  // ---------------------------------------------------------------- roles

  /** Built-in roles with their permissions, custom roles, and the permissions this actor may put into a custom role. */
  @RequirePermissions('staff.read')
  @Get('roles')
  async roles(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const ent = await this.licenses.entitlement(tx, a.tenantId!);
      const custom = await tx.customRole.findMany({ where: { deleted: false }, orderBy: { name: 'asc' }, include: { _count: { select: { assignments: true } } } });
      const grantable = [...limitToPlan(new Set(Object.keys(RESTAURANT_PERMISSIONS)), ent.features)].filter((p) => this.isOwner(a) || a.permissions.has(p));
      return {
        builtIn: (['owner', 'it_admin', 'cashier', 'waiter', 'chef', 'auditor'] as RestaurantRoleName[]).map((r) => ({
          role: r, permissions: [...limitToPlan(new Set(ROLE_PERMISSIONS[r]), ent.features)],
        })),
        custom: custom.map(({ _count, ...c }) => ({ ...c, seq: undefined, members: _count.assignments })),
        catalog: Object.entries(RESTAURANT_PERMISSIONS).map(([key, description]) => ({ key, description, grantable: grantable.includes(key) })),
        customRolesInPlan: ent.features.includes('roles.custom'),
      };
    });
  }

  private assertGrantable(a: Actor, ent: Ent, perms: string[]) {
    const inPlan = limitToPlan(new Set(perms), ent.features);
    const outOfPlan = perms.filter((p) => !inPlan.has(p));
    if (outOfPlan.length) throw forbidden('feature_not_in_plan', `Not in your plan: ${outOfPlan.join(', ')}`);
    const beyond = perms.filter((p) => !this.isOwner(a) && !a.permissions.has(p));
    if (beyond.length) throw forbidden('beyond_authority', `You cannot grant permissions you do not have: ${beyond.join(', ')}`);
  }

  @RequirePermissions('roles.manage')
  @RequiresFeature('roles.custom')
  @Audited('role.created')
  @Post('roles')
  @ApiBody(apiBody(RoleBody))
  async createRole(@CurrentActor() a: Actor, @Body(zbody(RoleBody)) b: z.infer<typeof RoleBody>, @AuditCtx() audit: AuditDetails) {
    const role = await this.t(a, async (tx) => {
      this.assertGrantable(a, await this.licenses.entitlement(tx, a.tenantId!), b.permissions);
      if (await tx.customRole.findFirst({ where: { name: b.name } })) throw conflict('role_exists', 'A role with that name exists');
      return tx.customRole.create({ data: { tenantId: a.tenantId!, name: b.name, description: b.description, permissions: [...new Set(b.permissions)] } });
    });
    Object.assign(audit, { objectType: 'custom_role', objectId: role.id, after: { name: role.name, permissions: role.permissions } });
    return { ...role, seq: undefined };
  }

  @RequirePermissions('roles.manage')
  @RequiresFeature('roles.custom')
  @Audited('role.updated')
  @Patch('roles/:id')
  @ApiBody(apiBody(RoleBody.partial()))
  async updateRole(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(RoleBody.partial())) b: Partial<z.infer<typeof RoleBody>>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.customRole.findUnique({ where: { id } });
      if (!before || before.deleted) throw notFound('Custom role');
      if (b.permissions) this.assertGrantable(a, await this.licenses.entitlement(tx, a.tenantId!), b.permissions);
      const after = await tx.customRole.update({ where: { id }, data: { name: b.name, description: b.description, permissions: b.permissions ? [...new Set(b.permissions)] : undefined } });
      // members' role rows get a new config seq so hubs pull the new permissions
      await tx.userRoleAssignment.updateMany({ where: { customRoleId: id }, data: { customRoleId: id } });
      return { before, after };
    });
    Object.assign(audit, {
      objectType: 'custom_role', objectId: id,
      before: { name: r.before.name, permissions: r.before.permissions }, after: { name: r.after.name, permissions: r.after.permissions },
    });
    return { ...r.after, seq: undefined };
  }

  @RequirePermissions('roles.manage')
  @RequiresFeature('roles.custom')
  @Audited('role.deleted')
  @Delete('roles/:id')
  @HttpCode(204)
  async deleteRole(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const before = await this.t(a, async (tx) => {
      const r = await tx.customRole.findUnique({ where: { id } });
      if (!r || r.deleted) throw notFound('Custom role');
      if (await tx.userRoleAssignment.count({ where: { customRoleId: id, user: { status: 'active' } } })) {
        throw conflict('role_in_use', 'Move the employees with this role to another role first');
      }
      await tx.customRole.update({ where: { id }, data: { deleted: true } });
      return r;
    });
    Object.assign(audit, { objectType: 'custom_role', objectId: id, before: { name: before.name, permissions: before.permissions } });
  }
}

