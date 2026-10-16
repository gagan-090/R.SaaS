import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Query, Res } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import type { Response } from 'express';
import { License, Prisma, TenantStatus } from '@prisma/client';
import { uuidv7 } from '../common/uuid';
import { z } from 'zod';
import { hashPassword } from '../auth/auth.service';
import { loadEnv } from '../config/env';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { AuditService } from '../common/audit.service';
import { randomToken, sha256 } from '../common/crypto';
import { Audited, authLimit, Public, RequirePermissions } from '../common/decorators';
import { badRequest, conflict, notFound } from '../common/errors';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService, Tx } from '../db/db.service';
import { verifyRestaurantEmail } from '../mail/templates';
import { LicenseService } from '../licensing/license.service';
import { Mailer } from '../mail/mail.service';
import { ColdStorage } from '../storage/cold-storage';

const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;

const RegisterBody = z.object({
  ownerEmail: z.string().email(),
  ownerName: z.string().trim().min(1).max(120),
  restaurantName: z.string().trim().min(1).max(160),
  gstin: z.string().regex(GSTIN, 'invalid GSTIN').optional(),
  address: z.string().max(500).optional(),
  planCode: z.string().regex(/^[a-z][a-z0-9_]{2,30}$/),
  billingCycle: z.enum(['monthly', 'yearly']).default('monthly'), // the customer pays monthly or yearly
  password: z.string().min(8, 'Use at least 8 characters').max(256).optional(),
});
const RegistrationQuery = z.object({ state: z.enum(['awaiting', 'expired', 'cancelled', 'all']).default('awaiting'), q: z.string().optional() });
const CancelBody = z.object({ reason: z.string().trim().min(3).max(500) });
const VerifyBody = z.object({
  token: z.string().min(1),
  // 8+ characters with a letter and a digit (same rule the console shows while typing)
  password: z.string().min(8, 'Use at least 8 characters').max(256)
    .refine((p) => /[A-Za-z]/.test(p) && /[0-9]/.test(p), 'Use letters and numbers'),
});
const ListQuery = z.object({
  q: z.string().optional(),
  status: z.nativeEnum(TenantStatus).optional(),
  plan: z.string().optional(),
  owner: z.string().optional(),
  expiresBefore: z.coerce.date().optional(),
  sort: z.enum(['name', 'createdAt', 'code']).default('createdAt'),
  page: z.coerce.number().int().min(1).default(1),
  pageSize: z.coerce.number().int().min(1).max(200).default(25),
});
const PatchBody = z.object({
  name: z.string().trim().min(1).max(160).optional(),
  gstin: z.string().regex(GSTIN, 'invalid GSTIN').nullable().optional(),
  address: z.string().max(500).nullable().optional(),
});
const StatusBody = z.object({
  action: z.enum(['activate', 'suspend', 'block', 'reactivate', 'archive', 'restore', 'delete']),
  reason: z.string().trim().min(3).max(500),
});
const LicenseBody = z.object({
  action: z.enum(['issue', 'renew', 'upgrade', 'downgrade', 'revoke']),
  planCode: z.string().optional(),
  billingCycle: z.enum(['monthly', 'yearly']).optional(), // default: the current license's cycle, else monthly
  endsAt: z.coerce.date().optional(),
  reason: z.string().trim().min(3).max(500),
});
const PaymentBody = z.object({
  amountPaise: z.number().int().positive(),
  method: z.enum(['bank', 'upi', 'cash', 'other']),
  reference: z.string().max(120).optional(),
  paidAt: z.coerce.date(),
  licenseId: z.string().uuid().optional(),
});

/** Allowed status transitions: Create -> Active <---> Suspend <---> Archived ---> Delete */
const TRANSITIONS: Record<z.infer<typeof StatusBody>['action'], { from: TenantStatus[]; to: TenantStatus }> = {
  activate: { from: ['pending', 'suspended'], to: 'active' },
  suspend: { from: ['active'], to: 'suspended' },
  block: { from: ['active', 'suspended'], to: 'blocked' },
  reactivate: { from: ['suspended', 'blocked'], to: 'active' },
  archive: { from: ['suspended'], to: 'archived' },
  restore: { from: ['archived'], to: 'suspended' },
  delete: { from: ['archived'], to: 'deleted' },
};

const addCycle = (from: Date, cycle: 'monthly' | 'yearly') => {
  const d = new Date(from);
  if (cycle === 'yearly') d.setUTCFullYear(d.getUTCFullYear() + 1);
  else d.setUTCMonth(d.getUTCMonth() + 1);
  return d;
};

const licenseView = (l: License & { plan?: { code: string; name: string } }) => ({
  id: l.id, planCode: l.plan?.code, planName: l.plan?.name, startsAt: l.startsAt, endsAt: l.endsAt,
  billingCycle: l.billingCycle, amountPaise: l.amountPaise,
  graceDays: l.graceDays, status: l.status, reason: l.reason, issuedBy: l.issuedBy, createdAt: l.createdAt,
});

@ApiTags('restaurants')
@ApiBearerAuth()
@Controller('restaurants')
export class RestaurantsController {
  constructor(private db: DbService, private licenses: LicenseService, private mailer: Mailer, private audit: AuditService, private coldStorage: ColdStorage) {}

  // ------------------------------------------------------------ onboarding (AC-01)

  @RequirePermissions('platform.restaurant.create')
  @Audited('restaurant.registered')
  @Post()
  @ApiBody(apiBody(RegisterBody))
  async register(@Body(zbody(RegisterBody)) b: z.infer<typeof RegisterBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const ownerEmail = b.ownerEmail.toLowerCase();
    const token = randomToken(32);

    if (b.password) {
      const passwordHash = await hashPassword(b.password);
      const created = await this.db.platform(async (tx) => {
        await this.assertEmailFree(tx, ownerEmail);
        const plan = await tx.subscriptionPlan.findUnique({ where: { code: b.planCode } });
        if (!plan || plan.archived) throw badRequest('unknown_plan', 'Choose an active plan');

        const seqRow = await tx.$queryRaw<{ n: bigint }[]>`SELECT nextval('tenant_code_seq') AS n`;
        const code = `R${String(seqRow[0].n).padStart(6, '0')}`;
        const tenant = await tx.restaurantTenant.create({
          data: { code, name: b.restaurantName, ownerEmail, gstin: b.gstin, address: b.address, status: 'active', statusChangedAt: new Date() },
        });
        const branch = await tx.branch.create({
          data: { tenantId: tenant.id, code: 'BR01', name: b.restaurantName, gstin: b.gstin, address: b.address },
        });
        const owner = await tx.user.create({
          data: {
            tenantId: tenant.id, name: b.ownerName, email: ownerEmail, passwordHash,
            roles: { create: { tenantId: tenant.id, role: 'owner', branchIds: [] } },
          },
        });
        const license = await this.createLicense(tx, tenant.id, plan, new Date(), addCycle(new Date(), b.billingCycle), actor.id, 'direct creation by super admin', b.billingCycle);
        const reg = await tx.restaurantRegistration.create({
          data: {
            ownerEmail, ownerName: b.ownerName, restaurantName: b.restaurantName, gstin: b.gstin, address: b.address,
            planCode: b.planCode, billingCycle: b.billingCycle, tokenHash: sha256(token), expiresAt: new Date(Date.now() + 72 * 3600_000), createdById: actor.id,
            verifiedAt: new Date(), tenantId: tenant.id,
          },
        });
        return { tenantId: tenant.id, restaurantCode: code, restaurantName: tenant.name, ownerEmail: owner.email, licenseId: license.id, registrationId: reg.id };
      });

      try {
        await this.mailer.send({ to: ownerEmail, subject: `Welcome to ${b.restaurantName} - Account Active`, text: `Your restaurant ${b.restaurantName} (${created.restaurantCode}) is active. Sign in with ${ownerEmail} and the password set by your admin.` });
      } catch {
        // Mailer failure does not block direct activation
      }

      Object.assign(audit, { objectType: 'restaurant', objectId: created.tenantId, after: { ...b, ownerEmail, status: 'active', restaurantCode: created.restaurantCode } });
      return { status: 'active' as const, ...created, emailSent: true as const };
    }

    const reg = await this.db.platform(async (tx) => {
      await this.assertEmailFree(tx, ownerEmail);
      const pending = await tx.restaurantRegistration.findFirst({
        where: { ownerEmail, verifiedAt: null, cancelledAt: null, expiresAt: { gt: new Date() } },
      });
      if (pending) throw conflict('duplicate_email', 'A registration for this email is already pending verification');
      const plan = await tx.subscriptionPlan.findUnique({ where: { code: b.planCode } });
      if (!plan || plan.archived) throw badRequest('unknown_plan', 'Choose an active plan');
      return tx.restaurantRegistration.create({
        data: {
          ownerEmail, ownerName: b.ownerName, restaurantName: b.restaurantName, gstin: b.gstin, address: b.address,
          planCode: b.planCode, billingCycle: b.billingCycle, tokenHash: sha256(token), expiresAt: new Date(Date.now() + 72 * 3600_000), createdById: actor.id,
        },
      });
    });
    const sent = await this.sendVerification(reg.id, token, { ownerEmail, ownerName: b.ownerName, restaurantName: b.restaurantName });
    Object.assign(audit, { objectType: 'restaurant_registration', objectId: reg.id, after: { ...b, ownerEmail, emailSent: sent.emailSent } });
    return { registrationId: reg.id, status: 'pending_verification', ownerEmail, ...sent };
  }

  /** Emails the activation link (console set-password page) and records the attempt on the registration. */
  private async sendVerification(regId: string, token: string, r: { ownerEmail: string; ownerName: string; restaurantName: string }) {
    const verifyUrl = `${loadEnv().CONSOLE_URL.replace(/\/$/, '')}/#/verify-email?token=${token}`;
    let emailError: string | undefined;
    try {
      await this.mailer.send({ to: r.ownerEmail, ...verifyRestaurantEmail({ ownerName: r.ownerName, restaurantName: r.restaurantName, url: verifyUrl }) });
    } catch (e) {
      // the registration stands; the Super Admin gets the link to pass on (or resends after fixing the mail setup)
      emailError = e instanceof Error ? e.message : 'Email could not be sent';
    }
    await this.db.platform((tx) => tx.restaurantRegistration.update({ where: { id: regId }, data: { lastSentAt: new Date(), lastEmailError: emailError ?? null } }));
    return emailError ? { emailSent: false as const, emailError, verifyUrl } : { emailSent: true as const };
  }

  // ---------------- registrations awaiting the owner's email confirmation

  /** Super Admin work queue: registrations not yet verified (awaiting, expired or cancelled). */
  @RequirePermissions('platform.restaurant.read')
  @Get('registrations')
  async registrations(@Query(new ZodPipe(RegistrationQuery)) q: z.infer<typeof RegistrationQuery>) {
    const now = new Date();
    const where: Prisma.RestaurantRegistrationWhereInput = {
      verifiedAt: null,
      ...(q.state === 'awaiting' ? { cancelledAt: null, expiresAt: { gt: now } } : {}),
      ...(q.state === 'expired' ? { cancelledAt: null, expiresAt: { lte: now } } : {}),
      ...(q.state === 'cancelled' ? { cancelledAt: { not: null } } : {}),
      ...(q.q ? { OR: [{ restaurantName: { contains: q.q, mode: 'insensitive' } }, { ownerEmail: { contains: q.q.toLowerCase() } }] } : {}),
    };
    return this.db.platform(async (tx) => {
      const [rows, counts] = await Promise.all([
        tx.restaurantRegistration.findMany({ where, orderBy: { createdAt: 'desc' }, take: 200 }),
        Promise.all([
          tx.restaurantRegistration.count({ where: { verifiedAt: null, cancelledAt: null, expiresAt: { gt: now } } }),
          tx.restaurantRegistration.count({ where: { verifiedAt: null, cancelledAt: null, expiresAt: { lte: now } } }),
        ]),
      ]);
      const plans = await tx.subscriptionPlan.findMany({ where: { code: { in: [...new Set(rows.map((r) => r.planCode))] } } });
      const planName = new Map(plans.map((p) => [p.code, p.name]));
      return {
        counts: { awaiting: counts[0], expired: counts[1] },
        items: rows.map((r) => ({
          id: r.id, restaurantName: r.restaurantName, ownerName: r.ownerName, ownerEmail: r.ownerEmail, gstin: r.gstin, address: r.address,
          planCode: r.planCode, planName: planName.get(r.planCode) ?? r.planCode, createdAt: r.createdAt, expiresAt: r.expiresAt,
          lastSentAt: r.lastSentAt, sendCount: r.sendCount, lastEmailError: r.lastEmailError, cancelledAt: r.cancelledAt, cancelReason: r.cancelReason,
          state: r.cancelledAt ? 'cancelled' : r.expiresAt <= now ? 'expired' : 'awaiting',
        })),
      };
    });
  }

  /** A fresh link (the old one stops working) valid for another 72 hours, emailed again. */
  @RequirePermissions('platform.restaurant.create')
  @Audited('restaurant.verification_resent')
  @Post('registrations/:id/resend')
  @HttpCode(200)
  async resend(@Param('id', ParseUUIDPipe) id: string, @AuditCtx() audit: AuditDetails) {
    const token = randomToken(32);
    const reg = await this.db.platform(async (tx) => {
      const r = await tx.restaurantRegistration.findUnique({ where: { id } });
      if (!r) throw notFound('Registration');
      if (r.verifiedAt) throw conflict('already_verified', 'The owner has already activated this restaurant');
      if (r.cancelledAt) throw conflict('cancelled', 'This registration was cancelled; register the restaurant again');
      await this.assertEmailFree(tx, r.ownerEmail);
      return tx.restaurantRegistration.update({
        where: { id }, data: { tokenHash: sha256(token), expiresAt: new Date(Date.now() + 72 * 3600_000), sendCount: { increment: 1 } },
      });
    });
    const sent = await this.sendVerification(reg.id, token, reg);
    Object.assign(audit, { objectType: 'restaurant_registration', objectId: id, after: { ownerEmail: reg.ownerEmail, sendCount: reg.sendCount, emailSent: sent.emailSent } });
    return { id, expiresAt: reg.expiresAt, sendCount: reg.sendCount, ...sent };
  }

  @RequirePermissions('platform.restaurant.create')
  @Audited('restaurant.registration_cancelled')
  @Post('registrations/:id/cancel')
  @HttpCode(200)
  @ApiBody(apiBody(CancelBody))
  async cancelRegistration(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(CancelBody)) b: z.infer<typeof CancelBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.db.platform(async (tx) => {
      const r = await tx.restaurantRegistration.findUnique({ where: { id } });
      if (!r) throw notFound('Registration');
      if (r.verifiedAt) throw conflict('already_verified', 'The owner has already activated this restaurant');
      if (r.cancelledAt) throw conflict('cancelled', 'Already cancelled');
      return tx.restaurantRegistration.update({ where: { id }, data: { cancelledAt: new Date(), cancelReason: b.reason } });
    });
    Object.assign(audit, { objectType: 'restaurant_registration', objectId: id, after: { ownerEmail: r.ownerEmail, cancelledAt: r.cancelledAt }, reason: b.reason });
    return { id, cancelledAt: r.cancelledAt };
  }

  @RequirePermissions('platform.restaurant.create')
  @Audited('restaurant.activated_by_admin')
  @Post('registrations/:id/activate')
  @ApiBody(apiBody(z.object({ password: z.string().min(12).max(128) })))
  async activateRegistration(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(z.object({ password: z.string().min(12).max(128) }))) b: { password: string }, @AuditCtx() audit: AuditDetails) {
    const token = randomToken(32);
    await this.db.platform(async tx => {
      const changed = await tx.restaurantRegistration.updateMany({ where: { id, verifiedAt: null, cancelledAt: null }, data: { tokenHash: sha256(token), expiresAt: new Date(Date.now() + 3600000) } });
      if (!changed.count) throw conflict('registration_unavailable', 'Registration is already activated or cancelled');
    });
    const result = await this.verifyEmail({ token, password: b.password });
    Object.assign(audit, { objectType: 'restaurant', objectId: result.tenantId, after: { activationMethod: 'admin_assisted', registrationId: id } });
    return result;
  }

  private async assertEmailFree(tx: Tx, email: string) {
    if (await tx.restaurantTenant.findUnique({ where: { ownerEmail: email } })) {
      throw conflict('duplicate_email', 'A restaurant with this owner email already exists');
    }
    if ((await tx.user.findUnique({ where: { email } })) || (await tx.platformAdmin.findUnique({ where: { email } }))) {
      throw conflict('duplicate_email', 'This email is already in use');
    }
  }

  /** Owner clicks the emailed link: creates the isolated tenant, main branch, owner user and a plan-bound license. */
  @Public()
  @Throttle(authLimit())
  @Post('verify-email')
  @HttpCode(201)
  @ApiBody(apiBody(VerifyBody))
  async verifyEmail(@Body(zbody(VerifyBody)) b: z.infer<typeof VerifyBody>) {
    const passwordHash = await hashPassword(b.password);
    return this.db.platform(async (tx) => {
      const reg = await tx.restaurantRegistration.findUnique({ where: { tokenHash: sha256(b.token) } });
      if (!reg || reg.expiresAt < new Date()) throw badRequest('invalid_token', 'Verification link is invalid or expired');
      if (reg.verifiedAt) throw conflict('already_verified', 'This email has already been verified');
      if (reg.cancelledAt) throw badRequest('invalid_token', 'This activation link was cancelled. Ask for a new one.');
      await this.assertEmailFree(tx, reg.ownerEmail);
      const plan = await tx.subscriptionPlan.findUnique({ where: { code: reg.planCode } });
      if (!plan) throw badRequest('unknown_plan', 'Plan no longer exists');

      const seqRow = await tx.$queryRaw<{ n: bigint }[]>`SELECT nextval('tenant_code_seq') AS n`;
      const code = `R${String(seqRow[0].n).padStart(6, '0')}`;
      const tenant = await tx.restaurantTenant.create({
        data: { code, name: reg.restaurantName, ownerEmail: reg.ownerEmail, gstin: reg.gstin, address: reg.address, status: 'active', statusChangedAt: new Date() },
      });
      const branch = await tx.branch.create({
        data: { tenantId: tenant.id, code: 'BR01', name: reg.restaurantName, gstin: reg.gstin, address: reg.address },
      });
      const owner = await tx.user.create({
        data: {
          tenantId: tenant.id, name: reg.ownerName, email: reg.ownerEmail, passwordHash,
          roles: { create: { tenantId: tenant.id, role: 'owner', branchIds: [] } },
        },
      });
      const license = await this.createLicense(tx, tenant.id, plan, new Date(), addCycle(new Date(), reg.billingCycle), reg.createdById, 'initial license at onboarding', reg.billingCycle);
      await tx.restaurantRegistration.update({ where: { id: reg.id }, data: { verifiedAt: new Date(), tenantId: tenant.id } });
      await this.audit.record(
        { action: 'restaurant.created', tenantId: tenant.id, objectType: 'restaurant', objectId: tenant.id, after: { code, name: tenant.name, plan: plan.code, licenseId: license.id } },
        { type: 'user', id: owner.id }, {}, tx,
      );
      return { tenantId: tenant.id, code, branchId: branch.id, ownerUserId: owner.id, license: licenseView({ ...license, plan }) };
    });
  }

  private async createLicense(tx: Tx, tenantId: string, plan: Prisma.SubscriptionPlanGetPayload<object>, startsAt: Date, endsAt: Date, issuedBy: string, reason: string, cycle: 'monthly' | 'yearly' = 'monthly') {
    const id = uuidv7();
    const draft = { id, tenantId, startsAt, endsAt, graceDays: 7 };
    const signedToken = this.licenses.buildToken(draft, plan);
    await tx.license.updateMany({ where: { tenantId, status: 'active' }, data: { status: 'superseded' } });
    return tx.license.create({
      data: {
        ...draft, planId: plan.id, status: 'active', signedToken, issuedBy, reason, billingCycle: cycle,
        amountPaise: cycle === 'yearly' ? plan.yearlyPricePaise : plan.pricePaise,
      },
    });
  }

  // ------------------------------------------------------------ list / detail

  @RequirePermissions('platform.restaurant.read')
  @Get()
  async list(@Query(new ZodPipe(ListQuery)) q: z.infer<typeof ListQuery>) {
    const where: Prisma.RestaurantTenantWhereInput = {
      status: q.status ?? { not: 'deleted' }, // deleted restaurants only when asked for
      ownerEmail: q.owner ? { contains: q.owner.toLowerCase() } : undefined,
      OR: q.q ? [{ name: { contains: q.q, mode: 'insensitive' } }, { code: { contains: q.q, mode: 'insensitive' } }] : undefined,
      licenses:
        q.plan || q.expiresBefore
          ? { some: { status: 'active', plan: q.plan ? { code: q.plan } : undefined, endsAt: q.expiresBefore ? { lte: q.expiresBefore } : undefined } }
          : undefined,
    };
    return this.db.platform(async (tx) => {
      const [rows, total] = await Promise.all([
        tx.restaurantTenant.findMany({
          where, orderBy: { [q.sort]: q.sort === 'createdAt' ? 'desc' : 'asc' }, skip: (q.page - 1) * q.pageSize, take: q.pageSize,
          include: { licenses: { where: { status: 'active' }, include: { plan: true }, take: 1 }, _count: { select: { branches: true } } },
        }),
        tx.restaurantTenant.count({ where }),
      ]);
      return {
        items: rows.map((t) => ({
          id: t.id, code: t.code, name: t.name, ownerEmail: t.ownerEmail, status: t.status, statusReason: t.statusReason,
          plan: t.licenses[0]?.plan.code ?? null, licenseEndsAt: t.licenses[0]?.endsAt ?? null, branches: t._count.branches, createdAt: t.createdAt,
        })),
        total, page: q.page, pageSize: q.pageSize,
      };
    });
  }

  @RequirePermissions('platform.restaurant.read')
  @Get(':id')
  async detail(@Param('id', ParseUUIDPipe) id: string) {
    return this.db.platform(async (tx) => {
      const t = await tx.restaurantTenant.findUnique({ where: { id }, include: { branches: true } });
      if (!t) throw notFound('Restaurant');
      const [licenses, devices, payments, archives] = await Promise.all([
        tx.license.findMany({ where: { tenantId: id }, include: { plan: true }, orderBy: { createdAt: 'desc' } }),
        tx.device.findMany({ where: { tenantId: id } }),
        tx.paymentRecord.findMany({ where: { tenantId: id }, orderBy: { paidAt: 'desc' } }),
        tx.restaurantArchive.findMany({ where: { tenantId: id }, orderBy: { createdAt: 'desc' } }),
      ]);
      const ent = await this.licenses.entitlement(tx, id);
      return {
        ...t, licenses: licenses.map(licenseView), currentLicense: ent.license ? licenseView({ ...ent.license, plan: licenses[0]?.plan }) : null,
        entitlement: { state: ent.state, readOnly: ent.readOnly, features: ent.features },
        devices: devices.map((d) => ({ ...d, deviceTokenHash: undefined })), payments, archives,
      };
    });
  }

  @RequirePermissions('platform.restaurant.update')
  @Audited('restaurant.updated')
  @Patch(':id')
  @ApiBody(apiBody(PatchBody))
  async update(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(PatchBody)) b: z.infer<typeof PatchBody>, @AuditCtx() audit: AuditDetails) {
    const { before, after } = await this.db.platform(async (tx) => {
      const before = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!before) throw notFound('Restaurant');
      const after = await tx.restaurantTenant.update({ where: { id }, data: b });
      return { before, after };
    });
    Object.assign(audit, { tenantId: id, objectType: 'restaurant', objectId: id, before, after });
    return after;
  }

  @RequirePermissions('platform.restaurant.status')
  @Audited('restaurant.status_changed')
  @Post(':id/status')
  @HttpCode(200)
  @ApiBody(apiBody(StatusBody))
  async setStatus(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(StatusBody)) b: z.infer<typeof StatusBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    if (b.action === 'archive') {
      return this.archive(id, { reason: b.reason }, actor, audit);
    }
    if (b.action === 'restore') {
      return this.restore(id, { reason: b.reason }, actor, audit);
    }
    if (b.action === 'delete') {
      return this.deleteRestaurant(id, { reason: b.reason }, actor, audit);
    }
    const rule = TRANSITIONS[b.action];
    const { before, after } = await this.db.platform(async (tx) => {
      const t = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!t) throw notFound('Restaurant');
      if (!rule.from.includes(t.status)) throw conflict('invalid_transition', `Cannot ${b.action} a ${t.status} restaurant`);
      const u = await tx.restaurantTenant.update({ where: { id }, data: { status: rule.to, statusReason: b.reason, statusChangedAt: new Date() } });
      return { before: t, after: u };
    });
    Object.assign(audit, { tenantId: id, objectType: 'restaurant', objectId: id, before: { status: before.status }, after: { status: after.status }, reason: b.reason });
    return { id, status: after.status, statusReason: after.statusReason };
  }

  /**
   * Cold storage archiving for restaurants in "suspended" status.
   * Bundles all restaurant data & logs into a compressed, verified document and transitions status to "archived".
   */
  @RequirePermissions('platform.restaurant.status')
  @Audited('restaurant.archived')
  @Post(':id/archive')
  @HttpCode(200)
  @ApiBody(apiBody(z.object({ reason: z.string().trim().min(3).max(500) })))
  async archive(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(z.object({ reason: z.string().trim().min(3).max(500) }))) b: { reason: string },
    @CurrentActor() actor: Actor,
    @AuditCtx() audit: AuditDetails,
  ) {
    const result = await this.db.platform(async (tx) => {
      const tenant = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!tenant) throw notFound('Restaurant');
      if (tenant.status !== 'suspended') {
        throw conflict('invalid_transition', `Only suspended restaurants can be archived (current status: ${tenant.status}). Suspend the restaurant first.`);
      }

      const [branches, users, licenses, payments, customRoles, auditEvents, syncEvents, devices, menuCategories, menuItems, floors, tables, reservations] = await Promise.all([
        tx.branch.findMany({ where: { tenantId: id } }),
        tx.user.findMany({ where: { tenantId: id }, include: { roles: true } }),
        tx.license.findMany({ where: { tenantId: id } }),
        tx.paymentRecord.findMany({ where: { tenantId: id } }),
        tx.customRole.findMany({ where: { tenantId: id } }),
        tx.auditEvent.findMany({ where: { tenantId: id }, orderBy: { at: 'asc' } }),
        tx.syncEvent.findMany({ where: { tenantId: id }, orderBy: { createdAt: 'asc' } }),
        tx.device.findMany({ where: { tenantId: id } }),
        tx.menuCategory.findMany({ where: { tenantId: id } }),
        tx.menuItem.findMany({ where: { tenantId: id }, include: { variants: true } }),
        tx.floor.findMany({ where: { tenantId: id } }),
        tx.table.findMany({ where: { tenantId: id } }),
        tx.tableReservation.findMany({ where: { tenantId: id } }),
      ]);

      const bundle = {
        version: 1,
        archivedAt: new Date().toISOString(),
        tenantId: id,
        restaurantCode: tenant.code,
        restaurantName: tenant.name,
        counts: {
          branches: branches.length,
          users: users.length,
          licenses: licenses.length,
          payments: payments.length,
          auditEvents: auditEvents.length,
          syncEvents: syncEvents.length,
          devices: devices.length,
          menuItems: menuItems.length,
          floors: floors.length,
          tables: tables.length,
          reservations: reservations.length,
        },
        data: {
          tenant,
          branches,
          users,
          licenses,
          payments,
          customRoles,
          auditEvents,
          syncEvents,
          devices,
          menuCategories,
          menuItems,
          floors,
          tables,
          reservations,
        },
      };

      const storageKey = `restaurants/${id}/${Date.now()}-archive.json.gz`;
      const stored = await this.coldStorage.put(storageKey, bundle);

      const archiveRecord = await tx.restaurantArchive.create({
        data: {
          tenantId: id,
          storage: stored.storage,
          storageKey: stored.key,
          sha256: stored.sha256,
          sizeBytes: stored.sizeBytes,
          counts: bundle.counts,
          createdBy: actor.id,
        },
      });

      const updated = await tx.restaurantTenant.update({
        where: { id },
        data: { status: 'archived', statusReason: b.reason, statusChangedAt: new Date() },
      });

      return { before: tenant, after: updated, archive: archiveRecord };
    });

    Object.assign(audit, {
      tenantId: id,
      objectType: 'restaurant',
      objectId: id,
      before: { status: result.before.status },
      after: { status: result.after.status, archiveId: result.archive.id, sha256: result.archive.sha256 },
      reason: b.reason,
    });

    return {
      id,
      status: 'archived',
      statusReason: result.after.statusReason,
      archiveId: result.archive.id,
      sha256: result.archive.sha256,
      sizeBytes: result.archive.sizeBytes,
      counts: result.archive.counts,
      message: 'Restaurant logs archived to cold storage. You can download the archive bundle for S3 cold storage tier.',
    };
  }

  /**
   * Downloads verified cold storage archive gzip bundle for S3 cold storage tier.
   */
  @RequirePermissions('platform.restaurant.read')
  @Get(':id/archive/download')
  async downloadArchive(@Param('id', ParseUUIDPipe) id: string, @Res() res: Response) {
    const [archive, tenant] = await this.db.platform(async (tx) => {
      const a = await tx.restaurantArchive.findFirst({
        where: { tenantId: id },
        orderBy: { createdAt: 'desc' },
      });
      const t = await tx.restaurantTenant.findUnique({ where: { id }, select: { code: true, name: true } });
      return [a, t] as const;
    });
    if (!archive) throw notFound('Archive');
    const bytes = await this.coldStorage.getVerified(archive.storageKey, archive.sha256);
    const filename = `restaurant-${tenant?.code ?? id}-archive.json.gz`;
    res.setHeader('content-type', 'application/gzip');
    res.setHeader('content-disposition', `attachment; filename="${filename}"`);
    res.setHeader('x-checksum-sha256', archive.sha256);
    res.send(bytes);
  }

  /**
   * Restores an archived restaurant back into "suspended" status after verifying checksums.
   * Following the requested flow: Archived -> Suspend -> Active.
   */
  @RequirePermissions('platform.restaurant.status')
  @Audited('restaurant.restored')
  @Post(':id/restore')
  @HttpCode(200)
  @ApiBody(apiBody(z.object({ reason: z.string().trim().min(3).max(500) })))
  async restore(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(z.object({ reason: z.string().trim().min(3).max(500) }))) b: { reason: string },
    @CurrentActor() actor: Actor,
    @AuditCtx() audit: AuditDetails,
  ) {
    const result = await this.db.platform(async (tx) => {
      const tenant = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!tenant) throw notFound('Restaurant');
      if (tenant.status !== 'archived') {
        throw conflict('invalid_transition', `Only archived restaurants can be restored (current status: ${tenant.status}).`);
      }
      const archive = await tx.restaurantArchive.findFirst({
        where: { tenantId: id },
        orderBy: { createdAt: 'desc' },
      });
      if (!archive) throw notFound('Archive');

      // Verify the archive exists and matches checksum
      await this.coldStorage.getVerified(archive.storageKey, archive.sha256);

      // Record restore metadata
      await tx.restaurantArchive.update({
        where: { id: archive.id },
        data: { restoredAt: new Date(), restoredBy: actor.id },
      });

      // Strictly transition to 'suspended'
      const updated = await tx.restaurantTenant.update({
        where: { id },
        data: { status: 'suspended', statusReason: `Restored: ${b.reason}`, statusChangedAt: new Date() },
      });

      return { before: tenant, after: updated, archive };
    });

    Object.assign(audit, {
      tenantId: id,
      objectType: 'restaurant',
      objectId: id,
      before: { status: result.before.status },
      after: { status: result.after.status },
      reason: b.reason,
    });

    return {
      id,
      status: 'suspended',
      statusReason: result.after.statusReason,
      message: 'Restaurant logs verified and restored from cold storage. Restaurant status transitioned to suspended. Ready for review and reactivation.',
    };
  }

  /**
   * Final deletion flow: A restaurant can only be deleted after being archived.
   */
  @RequirePermissions('platform.restaurant.status')
  @Audited('restaurant.deleted')
  @Post(':id/delete')
  @HttpCode(200)
  @ApiBody(apiBody(z.object({ reason: z.string().trim().min(3).max(500) })))
  async deleteRestaurant(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(z.object({ reason: z.string().trim().min(3).max(500) }))) b: { reason: string },
    @CurrentActor() actor: Actor,
    @AuditCtx() audit: AuditDetails,
  ) {
    const result = await this.db.platform(async (tx) => {
      const tenant = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!tenant) throw notFound('Restaurant');
      if (tenant.status !== 'archived') {
        throw conflict('invalid_transition', `A restaurant must be archived before it can be deleted (current status: ${tenant.status}).`);
      }
      const archive = await tx.restaurantArchive.findFirst({ where: { tenantId: id } });
      if (!archive) {
        throw conflict('no_archive', 'Cannot delete restaurant without a verified cold storage archive.');
      }

      // Mark tenant as deleted
      const updated = await tx.restaurantTenant.update({
        where: { id },
        data: { status: 'deleted', statusReason: b.reason, statusChangedAt: new Date() },
      });

      // Revoke any refresh tokens for users
      const tenantUsers = await tx.user.findMany({ where: { tenantId: id }, select: { id: true } });
      if (tenantUsers.length) {
        await tx.refreshToken.updateMany({
          where: { subjectType: 'user', subjectId: { in: tenantUsers.map((u) => u.id) }, revokedAt: null },
          data: { revokedAt: new Date() },
        });
      }

      return { before: tenant, after: updated };
    });

    Object.assign(audit, {
      tenantId: id,
      objectType: 'restaurant',
      objectId: id,
      before: { status: result.before.status },
      after: { status: result.after.status },
      reason: b.reason,
    });

    return { id, status: 'deleted', statusReason: result.after.statusReason };
  }

  // ------------------------------------------------------------ licensing

  @RequirePermissions('platform.restaurant.read')
  @Get(':id/licenses')
  async listLicenses(@Param('id', ParseUUIDPipe) id: string) {
    const rows = await this.db.platform((tx) => tx.license.findMany({ where: { tenantId: id }, include: { plan: true }, orderBy: { createdAt: 'desc' } }));
    return rows.map(licenseView);
  }

  @RequirePermissions('platform.license.manage')
  @Audited('license.changed')
  @Post(':id/licenses')
  @ApiBody(apiBody(LicenseBody))
  async licenseAction(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(LicenseBody)) b: z.infer<typeof LicenseBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const result = await this.db.platform(async (tx) => {
      const tenant = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!tenant) throw notFound('Restaurant');
      const current = await tx.license.findFirst({ where: { tenantId: id, status: 'active' }, include: { plan: true }, orderBy: { createdAt: 'desc' } });
      if (b.action === 'revoke') {
        if (!current) throw conflict('no_license', 'No active license to revoke');
        await tx.license.update({ where: { id: current.id }, data: { status: 'revoked', reason: b.reason } });
        return { before: licenseView(current), after: { ...licenseView(current), status: 'revoked' } };
      }
      if (b.action !== 'issue' && !current) throw conflict('no_license', `No active license to ${b.action}`);
      const planCode = b.planCode ?? current?.plan.code;
      if (!planCode) throw badRequest('plan_required', 'planCode is required');
      const plan = await tx.subscriptionPlan.findUnique({ where: { code: planCode } });
      if (!plan) throw badRequest('unknown_plan', 'Unknown plan');
      // renewing an archived plan keeps a restaurant where it is; moving onto one is not allowed
      if (plan.archived && plan.code !== current?.plan.code) throw badRequest('plan_archived', `${plan.name} is archived; choose an active plan`);
      if ((b.action === 'upgrade' || b.action === 'downgrade') && current) {
        // plans rank by tier (Standard 1 < Professional 2 < Premium 3); equal tiers by monthly price
        const dir = plan.tier !== current.plan.tier ? plan.tier - current.plan.tier : plan.pricePaise - current.plan.pricePaise;
        if (b.action === 'upgrade' ? dir <= 0 : dir >= 0) throw badRequest('invalid_plan_change', `${plan.code} is not a ${b.action} from ${current.plan.code}`);
      }
      const now = new Date();
      const cycle = b.billingCycle ?? current?.billingCycle ?? 'monthly';
      let startsAt = now;
      let endsAt: Date;
      if (b.action === 'renew' && current) {
        startsAt = current.startsAt;
        endsAt = b.endsAt ?? addCycle(current.endsAt > now ? current.endsAt : now, cycle);
      } else if (current && b.action !== 'issue') {
        startsAt = current.startsAt;
        endsAt = b.endsAt ?? current.endsAt; // plan change keeps the paid period
      } else {
        endsAt = b.endsAt ?? addCycle(now, cycle);
      }
      if (endsAt <= startsAt) throw badRequest('invalid_dates', 'endsAt must be after startsAt');
      const lic = await this.createLicense(tx, id, plan, startsAt, endsAt, actor.id, b.reason, cycle);
      return { before: current ? licenseView(current) : null, after: licenseView({ ...lic, plan }) };
    });
    Object.assign(audit, { tenantId: id, objectType: 'license', objectId: (result.after as { id: string }).id, before: result.before, after: result.after, reason: b.reason, action: `license.${b.action}` });
    return result.after;
  }

  @RequirePermissions('platform.restaurant.read')
  @Get(':id/licenses/current/token')
  async currentToken(@Param('id', ParseUUIDPipe) id: string) {
    const ent = await this.db.platform((tx) => this.licenses.entitlement(tx, id));
    if (!ent.token) throw notFound('Active license');
    return { token: ent.token, state: ent.state, readOnly: ent.readOnly, publicKey: loadEnv().LICENSE_PUBLIC_KEY };
  }

  @RequirePermissions('platform.payment.record')
  @Audited('payment.recorded')
  @Post(':id/payments')
  @ApiBody(apiBody(PaymentBody))
  async recordPayment(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(PaymentBody)) b: z.infer<typeof PaymentBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const p = await this.db.platform(async (tx) => {
      if (!(await tx.restaurantTenant.findUnique({ where: { id } }))) throw notFound('Restaurant');
      return tx.paymentRecord.create({ data: { tenantId: id, ...b, recordedBy: actor.id } });
    });
    Object.assign(audit, { tenantId: id, objectType: 'payment_record', objectId: p.id, after: p });
    return p;
  }
}
