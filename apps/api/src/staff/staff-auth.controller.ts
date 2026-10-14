import { Body, Controller, Headers, HttpCode, Ip, Post } from '@nestjs/common';
import { ApiBody, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import * as argon2 from 'argon2';
import { z } from 'zod';
import { AuditService } from '../common/audit.service';
import { randomToken, sha256 } from '../common/crypto';
import { authLimit, Public } from '../common/decorators';
import { badRequest, forbidden, unauthorized } from '../common/errors';
import { apiBody, zbody } from '../common/validation';
import { loadEnv } from '../config/env';
import { DbService } from '../db/db.service';
import { AuthService, hashPassword } from '../auth/auth.service';
import { LicenseService } from '../licensing/license.service';
import { Mailer } from '../mail/mail.service';
import { staffPinEmail } from '../mail/templates';
import { pinProblem } from './pin-policy';

const PinLoginBody = z.object({ email: z.string().trim().toLowerCase().email(), pin: z.string().regex(/^\d{4,8}$/, 'PIN is 4 to 8 digits') });
const EmailBody = z.object({ email: z.string().trim().toLowerCase().email() });
const TokenBody = z.object({ token: z.string().min(20).max(200) });
const CompleteBody = TokenBody.extend({ pin: z.string() });

/**
 * Employee web sign-in with email + PIN (plan feature "staff_portal"), and the one-time PIN links.
 * One email = one restaurant membership (emails are unique across the platform), so no restaurant picker is needed.
 * Failed attempts count towards the same 5-tries / 15-minute lockout as passwords; every route is IP-throttled.
 */
@ApiTags('auth')
@Controller('auth')
export class StaffAuthController {
  constructor(private db: DbService, private auth: AuthService, private audit: AuditService, private licenses: LicenseService, private mailer: Mailer) {}

  @Public()
  @Throttle(authLimit())
  @Post('pin-login')
  @HttpCode(200)
  @ApiBody(apiBody(PinLoginBody))
  async pinLogin(@Body(zbody(PinLoginBody)) b: z.infer<typeof PinLoginBody>, @Ip() ip: string, @Headers('user-agent') ua?: string) {
    const meta = { ip, userAgent: ua };
    const user = await this.db.platform((tx) => tx.user.findUnique({ where: { email: b.email }, include: { roles: true, tenant: true } }));
    const fail = async (code: string, msg: string, status: 401 | 403 = 401) => {
      await this.audit.record({ action: 'auth.login_failed', tenantId: user?.tenantId, objectType: 'user', objectId: user?.id, after: { email: b.email, code, method: 'pin' } }, null, meta);
      throw status === 401 ? unauthorized(code, msg) : forbidden(code, msg);
    };
    if (!user) {
      await argon2.hash(b.pin).catch(() => undefined); // same timing as a real check
      return fail('invalid_credentials', 'Invalid email or PIN');
    }
    if (user.lockedUntil && user.lockedUntil > new Date()) return fail('account_locked', 'Too many wrong PINs. Try again in 15 minutes or ask the owner to unlock you.');
    const valid = !!user.pinHash && (await argon2.verify(user.pinHash, b.pin).catch(() => false));
    if (!valid) {
      await this.auth.registerFailure({ typ: 'user', id: user.id, tid: user.tenantId });
      return fail('invalid_credentials', 'Invalid email or PIN');
    }
    // The PIN is right; from here the reasons can be specific.
    if (user.status !== 'active') return fail('inactive_account', 'Your account is turned off. Ask the owner.', 403);
    if (user.roles.some((r) => r.role === 'owner')) return fail('use_password', 'Owners sign in with email and password', 403);
    if (!user.webAccess) return fail('no_web_access', 'Web portal access is not turned on for you. Ask the owner.', 403);
    if (user.tenant.status !== 'active') return fail('restaurant_inactive', 'This restaurant is not active', 403);
    const ent = await this.db.tenant(user.tenantId, (tx) => this.licenses.entitlement(tx, user.tenantId));
    if (!ent.features.includes('staff_portal')) return fail('feature_not_in_plan', "Your restaurant's plan does not include the staff web portal", 403);
    if (pinProblem(b.pin)) return fail('pin_change_required', 'Your PIN is too simple for the web portal. Use "Forgot PIN" to choose a new one.', 403);
    await this.auth.clearFailures({ typ: 'user', id: user.id, tid: user.tenantId });
    const pair = await this.auth.issueTokens({ typ: 'user', id: user.id, tid: user.tenantId }, meta);
    await this.audit.record({ action: 'auth.login', tenantId: user.tenantId, objectType: 'user', objectId: user.id, after: { method: 'pin' } }, { type: 'user', id: user.id }, meta);
    return { status: 'ok' as const, ...pair };
  }

  /** "Forgot PIN": always answers the same way, so it never reveals whether an email exists. */
  @Public()
  @Throttle(authLimit())
  @Post('pin-reset-request')
  @HttpCode(202)
  @ApiBody(apiBody(EmailBody))
  async resetRequest(@Body(zbody(EmailBody)) b: z.infer<typeof EmailBody>, @Ip() ip: string) {
    const user = await this.db.platform((tx) => tx.user.findUnique({ where: { email: b.email }, include: { roles: true, tenant: true } }));
    if (user && user.status === 'active' && user.webAccess && !user.roles.some((r) => r.role === 'owner')) {
      const token = randomToken(32);
      await this.db.tenant(user.tenantId, async (tx) => {
        await tx.pinToken.updateMany({ where: { userId: user.id, usedAt: null }, data: { usedAt: new Date() } });
        await tx.pinToken.create({ data: { tenantId: user.tenantId, userId: user.id, tokenHash: sha256(token), purpose: 'reset', expiresAt: new Date(Date.now() + 72 * 3600_000) } });
      });
      const url = `${loadEnv().CONSOLE_URL.replace(/\/$/, '')}/#/set-pin?token=${token}`;
      await this.mailer.send({ to: b.email, ...staffPinEmail({ name: user.name, restaurantName: user.tenant.name, url, purpose: 'reset' }) }).catch(() => undefined);
      await this.audit.record({ action: 'staff.pin_reset_requested', tenantId: user.tenantId, objectType: 'user', objectId: user.id }, null, { ip });
    }
    return { ok: true, message: 'If that email belongs to an employee with web access, a link to choose a new PIN is on its way.' };
  }

  private async findToken(token: string) {
    const row = await this.db.platform((tx) => tx.pinToken.findUnique({ where: { tokenHash: sha256(token) }, include: { user: { include: { tenant: true } } } }));
    if (!row || row.usedAt || row.expiresAt < new Date()) throw badRequest('invalid_link', 'This link has expired or was already used. Ask the owner for a new one.');
    if (row.user.status !== 'active') throw badRequest('inactive_account', 'Your account is turned off. Ask the owner.');
    return row;
  }

  @Public()
  @Throttle(authLimit())
  @Post('pin-link/check')
  @HttpCode(200)
  @ApiBody(apiBody(TokenBody))
  async check(@Body(zbody(TokenBody)) b: z.infer<typeof TokenBody>) {
    const row = await this.findToken(b.token);
    return { name: row.user.name, email: row.user.email, restaurantName: row.user.tenant.name, purpose: row.purpose };
  }

  @Public()
  @Throttle(authLimit())
  @Post('pin-link/complete')
  @HttpCode(200)
  @ApiBody(apiBody(CompleteBody))
  async complete(@Body(zbody(CompleteBody)) b: z.infer<typeof CompleteBody>, @Ip() ip: string) {
    const problem = pinProblem(b.pin);
    if (problem) throw badRequest('weak_pin', problem);
    const row = await this.findToken(b.token);
    const pinHash = await hashPassword(b.pin);
    await this.db.tenant(row.tenantId, async (tx) => {
      const claimed = await tx.pinToken.updateMany({ where: { id: row.id, usedAt: null }, data: { usedAt: new Date() } });
      if (claimed.count === 0) throw badRequest('invalid_link', 'This link was already used');
      await tx.user.update({ where: { id: row.userId }, data: { pinHash, pinSetAt: new Date(), failedLoginCount: 0, lockedUntil: null } });
      await this.audit.record({ action: 'staff.pin_set_via_link', tenantId: row.tenantId, objectType: 'user', objectId: row.userId, after: { purpose: row.purpose } }, { type: 'user', id: row.userId }, { ip }, tx);
    });
    return { ok: true, email: row.user.email, webAccess: row.user.webAccess };
  }
}
