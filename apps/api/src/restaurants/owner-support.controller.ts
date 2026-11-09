import { Body, Controller, Get, Headers, HttpCode, Ip, Param, ParseUUIDPipe, Post, Req } from '@nestjs/common';
import { ApiBody, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import { AuthService, hashPassword } from '../auth/auth.service';
import type { Actor, AppRequest } from '../common/actor';
import { CurrentActor } from '../common/actor';
import { AuditService } from '../common/audit.service';
import { randomToken, sha256 } from '../common/crypto';
import { authLimit, Public, RequirePermissions } from '../common/decorators';
import { badRequest, conflict, forbidden, notFound } from '../common/errors';
import { apiBody, zbody } from '../common/validation';
import { loadEnv } from '../config/env';
import { DbService, Tx } from '../db/db.service';
import { Mailer } from '../mail/mail.service';
import { ownerPasswordResetEmail } from '../mail/templates';

const ReasonBody = z.object({ reason: z.string().trim().min(3).max(500) });
const TokenBody = z.object({ token: z.string().min(20).max(200) });
const CompleteBody = TokenBody.extend({ password: z.string().min(12, 'Use at least 12 characters').max(128) });

/** Password-reset links reuse the one-time link table (pin_tokens) with their own purpose; PIN routes ignore them. */
const PURPOSE = 'owner_password_reset';
const LINK_HOURS = 24;

async function findOwner(tx: Tx, tenantId: string) {
  const tenant = await tx.restaurantTenant.findUnique({ where: { id: tenantId } });
  if (!tenant) throw notFound('Restaurant');
  const owner = await tx.user.findFirst({
    where: { tenantId, roles: { some: { role: 'owner' } } },
    orderBy: { createdAt: 'asc' },
    include: { mfa: true },
  });
  if (!owner) throw notFound('Restaurant owner');
  if (!owner.email) throw conflict('owner_no_email', 'The owner account has no email address');
  return { tenant, owner: { ...owner, email: owner.email } };
}

/**
 * Support tools for a restaurant's first admin (the owner), used by the Super Admin from the restaurant page:
 * a one-time password reset link and an MFA reset. Both need platform.mfa.reset plus a fresh step-up token,
 * revoke the owner's sessions, notify the owner by email and are audited with the reason.
 */
@ApiTags('restaurants')
@Controller('restaurants')
export class OwnerSupportController {
  constructor(private db: DbService, private auth: AuthService, private audit: AuditService, private mailer: Mailer) {}

  /** What support needs to see before acting: who the owner is and whether MFA / a lockout is in place. */
  @RequirePermissions('platform.restaurant.read')
  @Get(':id/owner')
  async owner(@Param('id', ParseUUIDPipe) id: string) {
    return this.db.platform(async (tx) => {
      const { owner } = await findOwner(tx, id);
      const pending = await tx.pinToken.findFirst({ where: { userId: owner.id, purpose: PURPOSE, usedAt: null, expiresAt: { gt: new Date() } }, orderBy: { createdAt: 'desc' } });
      return {
        id: owner.id,
        name: owner.name,
        email: owner.email,
        status: owner.status,
        hasPassword: !!owner.passwordHash,
        mfaEnrolled: !!owner.mfa?.enrolledAt,
        lockedUntil: owner.lockedUntil && owner.lockedUntil > new Date() ? owner.lockedUntil : null,
        passwordResetPendingUntil: pending?.expiresAt ?? null,
      };
    });
  }

  @RequirePermissions('platform.mfa.reset')
  @Post(':id/owner/password-reset')
  @HttpCode(200)
  @ApiBody(apiBody(ReasonBody))
  async passwordReset(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(ReasonBody)) b: z.infer<typeof ReasonBody>,
    @Headers('x-step-up-token') stepUp: string | undefined,
    @CurrentActor() actor: Actor,
    @Req() req: AppRequest,
    @Ip() ip: string,
  ) {
    if (actor.type !== 'admin') throw forbidden('platform_only', 'Only platform admins can reset an owner password');
    this.auth.requireStepUp(actor, stepUp);
    const token = randomToken(32);
    const expiresAt = new Date(Date.now() + LINK_HOURS * 3600_000);
    const { tenant, owner } = await this.db.platform(async (tx) => {
      const found = await findOwner(tx, id);
      if (['archived', 'deleted'].includes(found.tenant.status)) throw conflict('restaurant_closed', 'Restore the restaurant before resetting its owner password');
      // only the newest link works
      await tx.pinToken.updateMany({ where: { userId: found.owner.id, purpose: PURPOSE, usedAt: null }, data: { usedAt: new Date() } });
      await tx.pinToken.create({ data: { tenantId: id, userId: found.owner.id, tokenHash: sha256(token), purpose: PURPOSE, createdBy: actor.id, expiresAt } });
      await this.audit.record(
        { action: 'restaurant.owner_password_reset_sent', tenantId: id, objectType: 'user', objectId: found.owner.id, after: { expiresAt: expiresAt.toISOString() }, reason: b.reason },
        actor, { ip, sessionId: actor.sessionId, requestId: req.requestId }, tx,
      );
      return found;
    });
    const link = `${loadEnv().CONSOLE_URL.replace(/\/$/, '')}/#/reset-password?token=${token}`;
    const emailed = await this.mailer
      .send({ to: owner.email, ...ownerPasswordResetEmail({ name: owner.name, restaurantName: tenant.name, url: link }) })
      .then(() => true)
      .catch(() => false);
    // the link is also shown once to the Super Admin, so support can pass it on if the email does not arrive
    return { ownerEmail: owner.email, emailed, link, expiresAt };
  }

  @RequirePermissions('platform.mfa.reset')
  @Post(':id/owner/mfa/reset')
  @HttpCode(200)
  @ApiBody(apiBody(ReasonBody))
  async mfaReset(
    @Param('id', ParseUUIDPipe) id: string,
    @Body(zbody(ReasonBody)) b: z.infer<typeof ReasonBody>,
    @Headers('x-step-up-token') stepUp: string | undefined,
    @CurrentActor() actor: Actor,
    @Req() req: AppRequest,
    @Ip() ip: string,
  ) {
    if (actor.type !== 'admin') throw forbidden('platform_only', 'Only platform admins can reset an owner MFA');
    this.auth.requireStepUp(actor, stepUp);
    const owner = await this.db.platform(async (tx) => {
      const { owner } = await findOwner(tx, id);
      if (!owner.mfa?.enrolledAt) throw conflict('mfa_not_enrolled', 'The owner has no authenticator set up, so there is nothing to reset');
      await tx.mFAEnrollment.update({
        where: { id: owner.mfa.id },
        data: { totpSecretEncrypted: '', recoveryCodeHashes: [], enrolledAt: null, lastUsedStep: null, resetById: actor.id, resetAt: new Date() },
      });
      await tx.refreshToken.updateMany({ where: { subjectType: 'user', subjectId: owner.id, revokedAt: null }, data: { revokedAt: new Date() } });
      await tx.notification.create({ data: { recipient: owner.email, type: 'mfa_reset', payload: { userId: owner.id, tenantId: id, resetBy: actor.id, reason: b.reason }, sentAt: new Date() } });
      await this.audit.record(
        { action: 'restaurant.owner_mfa_reset', tenantId: id, objectType: 'user', objectId: owner.id, before: { mfaEnrolled: true }, after: { mfaEnrolled: false }, reason: b.reason },
        actor, { ip, sessionId: actor.sessionId, requestId: req.requestId }, tx,
      );
      return owner;
    });
    await this.mailer
      .send({
        to: owner.email,
        subject: 'Your two-factor authentication was reset',
        text: `Support reset two-factor authentication on your owner account. Reason: ${b.reason}. Sign in with your password and set up your authenticator again. If this was unexpected, contact support.`,
      })
      .catch(() => undefined);
    return { id: owner.id, mfaReset: true, notified: owner.email };
  }
}

/** The owner's side of a support password reset: check the link, then choose a new password. */
@ApiTags('auth')
@Controller('auth')
export class OwnerPasswordLinkController {
  constructor(private db: DbService, private audit: AuditService) {}

  private async findToken(token: string) {
    const row = await this.db.platform((tx) =>
      tx.pinToken.findUnique({ where: { tokenHash: sha256(token) }, include: { user: { include: { tenant: true } } } }),
    );
    if (!row || row.purpose !== PURPOSE || row.usedAt || row.expiresAt < new Date()) {
      throw badRequest('invalid_link', 'This link has expired or was already used. Ask support for a new one.');
    }
    if (row.user.status !== 'active') throw badRequest('inactive_account', 'This account is turned off. Contact support.');
    return row;
  }

  @Public()
  @Throttle(authLimit())
  @Post('password-link/check')
  @HttpCode(200)
  @ApiBody(apiBody(TokenBody))
  async check(@Body(zbody(TokenBody)) b: z.infer<typeof TokenBody>) {
    const row = await this.findToken(b.token);
    return { name: row.user.name, email: row.user.email, restaurantName: row.user.tenant.name };
  }

  @Public()
  @Throttle(authLimit())
  @Post('password-link/complete')
  @HttpCode(200)
  @ApiBody(apiBody(CompleteBody))
  async complete(@Body(zbody(CompleteBody)) b: z.infer<typeof CompleteBody>, @Ip() ip: string) {
    const row = await this.findToken(b.token);
    const passwordHash = await hashPassword(b.password);
    await this.db.platform(async (tx) => {
      const claimed = await tx.pinToken.updateMany({ where: { id: row.id, usedAt: null }, data: { usedAt: new Date() } });
      if (claimed.count === 0) throw badRequest('invalid_link', 'This link was already used');
      await tx.user.update({ where: { id: row.userId }, data: { passwordHash, failedLoginCount: 0, lockedUntil: null } });
      // every existing session ends: whoever had the old password is signed out
      await tx.refreshToken.updateMany({ where: { subjectType: 'user', subjectId: row.userId, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.audit.record(
        { action: 'restaurant.owner_password_reset_completed', tenantId: row.tenantId, objectType: 'user', objectId: row.userId },
        { type: 'user', id: row.userId }, { ip }, tx,
      );
    });
    return { ok: true, email: row.user.email };
  }
}
