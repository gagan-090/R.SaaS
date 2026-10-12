import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { ApiBody, ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
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
import { PLAN_DEFAULTS } from '../common/permissions';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService, Tx } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';
import { Mailer } from '../mail/mail.service';

const GSTIN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;

const RegisterBody = z.object({
  ownerEmail: z.string().email(),
  ownerName: z.string().trim().min(1).max(120),
  restaurantName: z.string().trim().min(1).max(160),
  gstin: z.string().regex(GSTIN, 'invalid GSTIN').optional(),
  address: z.string().max(500).optional(),
  planCode: z.enum(PLAN_DEFAULTS.map((p) => p.code) as [string, ...string[]]),
});
const VerifyBody = z.object({ token: z.string().min(1), password: z.string().min(12).max(256) });
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
  action: z.enum(['activate', 'suspend', 'block', 'reactivate']),
  reason: z.string().trim().min(3).max(500),
});
const LicenseBody = z.object({
  action: z.enum(['issue', 'renew', 'upgrade', 'downgrade', 'revoke']),
  planCode: z.string().optional(),
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

/** Allowed status transitions (Build Spec §06). */
const TRANSITIONS: Record<z.infer<typeof StatusBody>['action'], { from: TenantStatus[]; to: TenantStatus }> = {
  activate: { from: ['pending'], to: 'active' },
  suspend: { from: ['active'], to: 'suspended' },
  block: { from: ['active', 'suspended'], to: 'blocked' },
  reactivate: { from: ['suspended', 'blocked'], to: 'active' },
};

const addCycle = (from: Date, cycle: 'monthly' | 'yearly') => {
  const d = new Date(from);
  if (cycle === 'yearly') d.setUTCFullYear(d.getUTCFullYear() + 1);
  else d.setUTCMonth(d.getUTCMonth() + 1);
  return d;
};

const licenseView = (l: License & { plan?: { code: string; name: string } }) => ({
  id: l.id, planCode: l.plan?.code, planName: l.plan?.name, startsAt: l.startsAt, endsAt: l.endsAt,
  graceDays: l.graceDays, status: l.status, reason: l.reason, issuedBy: l.issuedBy, createdAt: l.createdAt,
});

@ApiTags('restaurants')
@ApiBearerAuth()
@Controller('restaurants')
export class RestaurantsController {
  constructor(private db: DbService, private licenses: LicenseService, private mailer: Mailer, private audit: AuditService) {}

  // ------------------------------------------------------------ onboarding (AC-01)

  @RequirePermissions('platform.restaurant.create')
  @Audited('restaurant.registered')
  @Post()
  @ApiBody(apiBody(RegisterBody))
  async register(@Body(zbody(RegisterBody)) b: z.infer<typeof RegisterBody>, @CurrentActor() actor: Actor, @AuditCtx() audit: AuditDetails) {
    const ownerEmail = b.ownerEmail.toLowerCase();
    const token = randomToken(32);
    const reg = await this.db.platform(async (tx) => {
      await this.assertEmailFree(tx, ownerEmail);
      const pending = await tx.restaurantRegistration.findFirst({
        where: { ownerEmail, verifiedAt: null, expiresAt: { gt: new Date() } },
      });
      if (pending) throw conflict('duplicate_email', 'A registration for this email is already pending verification');
      return tx.restaurantRegistration.create({
        data: {
          ownerEmail, ownerName: b.ownerName, restaurantName: b.restaurantName, gstin: b.gstin, address: b.address,
          planCode: b.planCode, tokenHash: sha256(token), expiresAt: new Date(Date.now() + 72 * 3600_000), createdById: actor.id,
        },
      });
    });
    await this.mailer.send({
      to: ownerEmail,
      subject: `Verify your email to activate ${b.restaurantName}`,
      text: `Confirm your email and set your password (valid 72 hours): ${loadEnv().PUBLIC_API_URL}/verify-email?token=${token}`,
    });
    Object.assign(audit, { objectType: 'restaurant_registration', objectId: reg.id, after: { ...b, ownerEmail } });
    return { registrationId: reg.id, status: 'pending_verification', ownerEmail };
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
      await this.assertEmailFree(tx, reg.ownerEmail);
      const plan = await tx.subscriptionPlan.findUnique({ where: { code: reg.planCode } });
      if (!plan) throw badRequest('unknown_plan', 'Plan no longer exists');

      const seqRow = await tx.$queryRaw<{ n: bigint }[]>`SELECT nextval('tenant_code_seq') AS n`;
      const code = `R${String(seqRow[0].n).padStart(6, '0')}`;
      const tenant = await tx.restaurantTenant.create({
        data: { code, name: reg.restaurantName, ownerEmail: reg.ownerEmail, gstin: reg.gstin, address: reg.address, status: 'active' },
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
      const license = await this.createLicense(tx, tenant.id, plan, new Date(), addCycle(new Date(), plan.billingCycle), reg.createdById, 'initial license at onboarding');
      await tx.restaurantRegistration.update({ where: { id: reg.id }, data: { verifiedAt: new Date(), tenantId: tenant.id } });
      await this.audit.record(
        { action: 'restaurant.created', tenantId: tenant.id, objectType: 'restaurant', objectId: tenant.id, after: { code, name: tenant.name, plan: plan.code, licenseId: license.id } },
        { type: 'user', id: owner.id }, {}, tx,
      );
      return { tenantId: tenant.id, code, branchId: branch.id, ownerUserId: owner.id, license: licenseView({ ...license, plan }) };
    });
  }

  private async createLicense(tx: Tx, tenantId: string, plan: Prisma.SubscriptionPlanGetPayload<object>, startsAt: Date, endsAt: Date, issuedBy: string, reason: string) {
    const id = uuidv7();
    const draft = { id, tenantId, startsAt, endsAt, graceDays: 7 };
    const signedToken = this.licenses.buildToken(draft, plan);
    await tx.license.updateMany({ where: { tenantId, status: 'active' }, data: { status: 'superseded' } });
    return tx.license.create({ data: { ...draft, planId: plan.id, status: 'active', signedToken, issuedBy, reason } });
  }

  // ------------------------------------------------------------ list / detail

  @RequirePermissions('platform.restaurant.read')
  @Get()
  async list(@Query(new ZodPipe(ListQuery)) q: z.infer<typeof ListQuery>) {
    const where: Prisma.RestaurantTenantWhereInput = {
      status: q.status,
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
      const [licenses, devices, payments] = await Promise.all([
        tx.license.findMany({ where: { tenantId: id }, include: { plan: true }, orderBy: { createdAt: 'desc' } }),
        tx.device.findMany({ where: { tenantId: id } }),
        tx.paymentRecord.findMany({ where: { tenantId: id }, orderBy: { paidAt: 'desc' } }),
      ]);
      const ent = await this.licenses.entitlement(tx, id);
      return {
        ...t, licenses: licenses.map(licenseView), currentLicense: ent.license ? licenseView({ ...ent.license, plan: licenses[0]?.plan }) : null,
        entitlement: { state: ent.state, readOnly: ent.readOnly, features: ent.features },
        devices: devices.map((d) => ({ ...d, deviceTokenHash: undefined })), payments,
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
  async setStatus(@Param('id', ParseUUIDPipe) id: string, @Body(zbody(StatusBody)) b: z.infer<typeof StatusBody>, @AuditCtx() audit: AuditDetails) {
    const rule = TRANSITIONS[b.action];
    const { before, after } = await this.db.platform(async (tx) => {
      const t = await tx.restaurantTenant.findUnique({ where: { id } });
      if (!t) throw notFound('Restaurant');
      if (!rule.from.includes(t.status)) throw conflict('invalid_transition', `Cannot ${b.action} a ${t.status} restaurant`);
      const u = await tx.restaurantTenant.update({ where: { id }, data: { status: rule.to, statusReason: b.reason } });
      return { before: t, after: u };
    });
    Object.assign(audit, { tenantId: id, objectType: 'restaurant', objectId: id, before: { status: before.status }, after: { status: after.status }, reason: b.reason });
    return { id, status: after.status, statusReason: after.statusReason };
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
      if ((b.action === 'upgrade' || b.action === 'downgrade') && current) {
        const rank = (c: string) => PLAN_DEFAULTS.findIndex((p) => p.code === c);
        const dir = rank(plan.code) - rank(current.plan.code);
        if (b.action === 'upgrade' ? dir <= 0 : dir >= 0) throw badRequest('invalid_plan_change', `${plan.code} is not a ${b.action} from ${current.plan.code}`);
      }
      const now = new Date();
      let startsAt = now;
      let endsAt: Date;
      if (b.action === 'renew' && current) {
        startsAt = current.startsAt;
        endsAt = b.endsAt ?? addCycle(current.endsAt > now ? current.endsAt : now, plan.billingCycle);
      } else if (current && b.action !== 'issue') {
        startsAt = current.startsAt;
        endsAt = b.endsAt ?? current.endsAt; // plan change keeps the paid period
      } else {
        endsAt = b.endsAt ?? addCycle(now, plan.billingCycle);
      }
      if (endsAt <= startsAt) throw badRequest('invalid_dates', 'endsAt must be after startsAt');
      const lic = await this.createLicense(tx, id, plan, startsAt, endsAt, actor.id, b.reason);
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
