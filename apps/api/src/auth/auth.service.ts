import { Injectable } from '@nestjs/common';
import * as argon2 from 'argon2';
import { authenticator } from 'otplib';
import { uuidv7 } from '../common/uuid';
import { loadEnv } from '../config/env';
import type { Actor } from '../common/actor';
import { AuditMeta, AuditService } from '../common/audit.service';
import { decrypt, encrypt, randomToken, sha256 } from '../common/crypto';
import { badRequest, conflict, forbidden, unauthorized } from '../common/errors';
import { DbService, Tx } from '../db/db.service';
import { TokensService } from './tokens.service';

authenticator.options = { window: 1, step: 30 };

const MAX_FAILED = 5;
const LOCK_MINUTES = 15;
const REFRESH_DAYS = 30;
const RECOVERY_CODES = 10;

/** Argon2id with OWASP-recommended parameters. */
export const hashPassword = (p: string) =>
  argon2.hash(p, { type: argon2.argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 });

export interface Principal {
  typ: 'admin' | 'user';
  id: string;
  tid?: string;
  mfaVerified?: boolean;
}

const claimsOf = (p: Principal) => ({ sub: p.id, typ: p.typ, tid: p.tid });

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export type LoginResult =
  | ({ status: 'ok' } & TokenPair)
  | { status: 'mfa_required'; challengeToken: string }
  | { status: 'mfa_enrollment_required'; enrollmentToken: string };

@Injectable()
export class AuthService {
  constructor(private db: DbService, private tokens: TokensService, private audit: AuditService) {}

  // ------------------------------------------------------------------ login

  async login(emailRaw: string, password: string, meta: AuditMeta & { userAgent?: string }): Promise<LoginResult> {
    const email = emailRaw.trim().toLowerCase();
    // Lookup crosses tenants (email is globally unique), so it runs in platform context.
    const found = await this.db.platform(async (tx) => {
      const admin = await tx.platformAdmin.findUnique({ where: { email }, include: { mfa: true } });
      if (admin) return { kind: 'admin' as const, admin };
      const user = await tx.user.findUnique({ where: { email }, include: { mfa: true, tenant: true } });
      return user ? { kind: 'user' as const, user } : null;
    });

    const fail = async (code: string, msg: string, p?: Principal, tenantId?: string) => {
      await this.audit.record({ action: 'auth.login_failed', tenantId, objectType: p?.typ, objectId: p?.id, after: { email, code } }, null, meta);
      throw unauthorized(code, msg);
    };

    if (!found) {
      await argon2.hash(password).catch(() => undefined); // equalise timing for unknown emails
      return fail('invalid_credentials', 'Invalid email or password');
    }

    const rec = found.kind === 'admin' ? found.admin : found.user;
    const principal: Principal =
      found.kind === 'admin' ? { typ: 'admin', id: rec.id } : { typ: 'user', id: rec.id, tid: found.user.tenantId };
    const tenantId = principal.tid;

    if (rec.lockedUntil && rec.lockedUntil > new Date()) {
      return fail('account_locked', `Too many failed attempts; try again after ${rec.lockedUntil.toISOString()}`, principal, tenantId);
    }
    // archived or deleted restaurants are closed: nobody of theirs signs in until the Super Admin restores them
    const closed = found.kind === 'user' && ['archived', 'deleted'].includes(found.user.tenant.status);
    const statusOk = found.kind === 'admin' ? found.admin.status === 'active' : found.user.status === 'active' && !closed;
    const valid = !!rec.passwordHash && (await argon2.verify(rec.passwordHash, password).catch(() => false));
    if (!valid || !statusOk) {
      await this.registerFailure(principal);
      return fail('invalid_credentials', 'Invalid email or password', principal, tenantId);
    }
    await this.clearFailures(principal);

    const mfa = rec.mfa;
    const mfaEnabled = found.kind !== 'admin' || found.admin.mfaEnabled;
    if (mfaEnabled && mfa?.enrolledAt) {
      return { status: 'mfa_required', challengeToken: this.tokens.sign(claimsOf(principal), 'mfa-challenge') };
    }
    if (principal.typ === 'admin' && mfaEnabled) {
      // Super Admins choose the MFA policy per account; enabled accounts must enrol before access.
      return { status: 'mfa_enrollment_required', enrollmentToken: this.tokens.sign(claimsOf(principal), 'mfa-enroll') };
    }
    const pair = await this.issueTokens(principal, meta);
    await this.audit.record({ action: 'auth.login', tenantId, objectType: principal.typ, objectId: principal.id }, { type: principal.typ, id: principal.id }, meta);
    return { status: 'ok', ...pair };
  }

  async registerFailure(p: Principal) {
    await this.db.platform(async (tx) => {
      const model = (p.typ === 'admin' ? tx.platformAdmin : tx.user) as unknown as {
        update(args: object): Promise<{ failedLoginCount: number }>;
      };
      const r = await model.update({ where: { id: p.id }, data: { failedLoginCount: { increment: 1 } } });
      if (r.failedLoginCount >= MAX_FAILED) {
        await model.update({
          where: { id: p.id },
          data: { failedLoginCount: 0, lockedUntil: new Date(Date.now() + LOCK_MINUTES * 60_000) },
        });
      }
    });
  }

  async clearFailures(p: Principal) {
    await this.db.platform(async (tx) => {
      const data = { failedLoginCount: 0, lockedUntil: null };
      if (p.typ === 'admin') await tx.platformAdmin.update({ where: { id: p.id }, data: { ...data, lastLoginAt: new Date() } });
      else await tx.user.update({ where: { id: p.id }, data });
    });
  }

  // ------------------------------------------------------------------ tokens

  async issueTokens(p: Principal, meta: AuditMeta & { userAgent?: string }, familyId = uuidv7(), tx?: Tx): Promise<TokenPair> {
    const sid = familyId;
    const refreshToken = randomToken(32);
    const write = async (t: Tx) => {
      if (p.typ === 'admin') {
        await t.$queryRaw`SELECT id FROM platform_admins WHERE id = ${p.id}::uuid FOR UPDATE`;
        const admin = await t.platformAdmin.findUnique({ where: { id: p.id }, select: { status: true, mfaEnabled: true } });
        if (!admin || admin.status !== 'active') throw unauthorized('inactive_account');
        if (admin.mfaEnabled && !p.mfaVerified) throw unauthorized('mfa_required', 'MFA settings changed. Sign in again.');
      }
      return t.refreshToken.create({
        data: {
          subjectType: p.typ, subjectId: p.id, familyId, tokenHash: sha256(refreshToken),
          expiresAt: new Date(Date.now() + REFRESH_DAYS * 86400_000), userAgent: meta.userAgent, ip: meta.ip,
        },
      });
    };
    if (tx) await write(tx);
    else await this.db.platform(write);
    return { accessToken: this.tokens.sign({ sub: p.id, typ: p.typ, tid: p.tid, sid }, 'access'), refreshToken, expiresIn: 900 };
  }

  /** Rotating refresh: each token is single-use; reusing a rotated token revokes the whole family (theft signal). */
  async refresh(refreshToken: string, meta: AuditMeta & { userAgent?: string }): Promise<TokenPair> {
    const outcome = await this.db.platform(async (tx) => {
      const row = await tx.refreshToken.findUnique({ where: { tokenHash: sha256(refreshToken) } });
      if (!row) throw unauthorized('invalid_refresh', 'Invalid refresh token');
      if (row.revokedAt) return { reused: row, pair: null }; // handled outside so the revocation is not rolled back
      if (row.expiresAt < new Date()) throw unauthorized('refresh_expired', 'Refresh token expired');
      let tid: string | undefined;
      if (row.subjectType === 'user') {
        const u = await tx.user.findUnique({ where: { id: row.subjectId }, include: { tenant: { select: { status: true } } } });
        if (!u || u.status !== 'active' || ['archived', 'deleted'].includes(u.tenant.status)) throw unauthorized('inactive_account');
        tid = u.tenantId;
      } else {
        await tx.$queryRaw`SELECT id FROM platform_admins WHERE id = ${row.subjectId}::uuid FOR UPDATE`;
        const a = await tx.platformAdmin.findUnique({ where: { id: row.subjectId } });
        if (!a || a.status !== 'active') throw unauthorized('inactive_account');
      }
      // Claim the old token first; a concurrent refresh with the same token then sees it revoked.
      const claimed = await tx.refreshToken.updateMany({ where: { id: row.id, revokedAt: null }, data: { revokedAt: new Date() } });
      if (claimed.count === 0) return { reused: row, pair: null };
      const pair = await this.issueTokens({ typ: row.subjectType, id: row.subjectId, tid, mfaVerified: row.subjectType === 'admin' }, meta, row.familyId, tx);
      const next = await tx.refreshToken.findUnique({ where: { tokenHash: sha256(pair.refreshToken) } });
      await tx.refreshToken.update({ where: { id: row.id }, data: { replacedBy: next?.id } });
      return { pair, reused: null };
    });
    if (outcome.pair) return outcome.pair;
    const row = outcome.reused!;
    await this.db.platform(async (tx) => {
      await tx.refreshToken.updateMany({ where: { familyId: row.familyId, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.audit.record({ action: 'auth.refresh_reuse_detected', objectType: row.subjectType, objectId: row.subjectId }, null, meta, tx);
    });
    throw unauthorized('refresh_reused', 'Refresh token reuse detected; please sign in again');
  }

  async logout(refreshToken: string, actor: Actor | null, meta: AuditMeta) {
    await this.db.platform(async (tx) => {
      const row = await tx.refreshToken.findUnique({ where: { tokenHash: sha256(refreshToken) } });
      if (!row) return;
      await tx.refreshToken.updateMany({ where: { familyId: row.familyId, revokedAt: null }, data: { revokedAt: new Date() } });
      await this.audit.record({ action: 'auth.logout', objectType: row.subjectType, objectId: row.subjectId }, actor, meta, tx);
    });
  }

  // ------------------------------------------------------------------ MFA

  private key() {
    return loadEnv().MFA_ENCRYPTION_KEY;
  }

  private mfaWhere(p: Principal) {
    return p.typ === 'admin' ? { adminId: p.id } : { userId: p.id };
  }

  async enrollStart(p: Principal, accountLabel: string) {
    return this.db.platform(async (tx) => {
      const existing = await tx.mFAEnrollment.findUnique({ where: this.mfaWhere(p) as never });
      if (existing?.enrolledAt) throw conflict('mfa_already_enrolled', 'MFA is already enrolled');
      const secret = authenticator.generateSecret(20);
      const enc = encrypt(secret, this.key());
      if (existing) await tx.mFAEnrollment.update({ where: { id: existing.id }, data: { totpSecretEncrypted: enc, recoveryCodeHashes: [] } });
      else await tx.mFAEnrollment.create({ data: { ...this.mfaWhere(p), totpSecretEncrypted: enc, recoveryCodeHashes: [] } });
      // The secret is returned once, to the enrolling principal only, so the authenticator app can be set up.
      return { secret, otpauthUrl: authenticator.keyuri(accountLabel, 'Restaurant SaaS', secret) };
    });
  }

  async enrollConfirm(p: Principal, code: string, meta: AuditMeta & { userAgent?: string }) {
    return this.db.platform(async (tx) => {
      const e = await tx.mFAEnrollment.findUnique({ where: this.mfaWhere(p) as never });
      if (!e || e.enrolledAt) throw conflict('mfa_not_pending', 'No pending MFA enrolment');
      const step = this.checkTotp(decrypt(e.totpSecretEncrypted, this.key()), code, null);
      if (step === null) throw badRequest('invalid_code', 'Invalid authenticator code');
      const codes = Array.from({ length: RECOVERY_CODES }, () => randomToken(6).replace(/[-_]/g, 'x').slice(0, 10).toUpperCase());
      await tx.mFAEnrollment.update({
        where: { id: e.id },
        data: { enrolledAt: new Date(), lastUsedStep: step, recoveryCodeHashes: codes.map((c) => sha256(c)) },
      });
      await this.audit.record({ action: 'mfa.enrolled', tenantId: p.tid, objectType: p.typ, objectId: p.id }, { type: p.typ, id: p.id }, meta, tx);
      return { recoveryCodes: codes };
    });
  }

  /** Returns the matched time step, or null. Rejects a step at or before lastUsedStep (replay). */
  private checkTotp(secret: string, code: string, lastUsedStep: number | null): number | null {
    if (!/^\d{6}$/.test(code)) return null;
    const now = Math.floor(Date.now() / 1000 / 30);
    for (const delta of [0, -1, 1]) {
      const step = now + delta;
      const expected = authenticator.clone({ epoch: step * 30 * 1000, window: 0 }).generate(secret);
      if (expected === code && (lastUsedStep === null || step > lastUsedStep)) return step;
    }
    return null;
  }

  /** Verifies a TOTP or a single-use recovery code for an enrolled principal. Consumes recovery codes. */
  async verifySecondFactor(tx: Tx, p: Principal, input: { code?: string; recoveryCode?: string }): Promise<boolean> {
    const e = await tx.mFAEnrollment.findUnique({ where: this.mfaWhere(p) as never });
    if (!e?.enrolledAt) return false;
    if (input.code) {
      const step = this.checkTotp(decrypt(e.totpSecretEncrypted, this.key()), input.code, e.lastUsedStep);
      if (step === null) return false;
      await tx.mFAEnrollment.update({ where: { id: e.id }, data: { lastUsedStep: step } });
      return true;
    }
    if (input.recoveryCode) {
      const h = sha256(input.recoveryCode.trim().toUpperCase());
      if (!e.recoveryCodeHashes.includes(h)) return false;
      await tx.mFAEnrollment.update({ where: { id: e.id }, data: { recoveryCodeHashes: e.recoveryCodeHashes.filter((x) => x !== h) } });
      return true;
    }
    return false;
  }

  async mfaVerify(challengeToken: string, input: { code?: string; recoveryCode?: string }, meta: AuditMeta & { userAgent?: string }) {
    const c = this.tokens.verify(challengeToken, 'mfa-challenge');
    const p: Principal = { typ: c.typ, id: c.sub, tid: c.tid };
    const ok = await this.db.platform((tx) => this.verifySecondFactor(tx, p, input));
    if (!ok) {
      await this.audit.record({ action: 'auth.mfa_failed', tenantId: p.tid, objectType: p.typ, objectId: p.id }, null, meta);
      await this.registerFailure(p);
      throw unauthorized('invalid_code', 'Invalid authenticator or recovery code');
    }
    const pair = await this.issueTokens({ ...p, mfaVerified: true }, meta);
    await this.audit.record(
      { action: input.recoveryCode ? 'auth.login_recovery_code' : 'auth.login', tenantId: p.tid, objectType: p.typ, objectId: p.id },
      { type: p.typ, id: p.id }, meta,
    );
    return pair;
  }

  /** Step-up: re-verify password + current TOTP; returns a 5-minute step-up token bound to the principal. */
  async stepUp(actor: Actor, password: string, code: string | undefined, meta: AuditMeta) {
    const p: Principal = { typ: actor.type, id: actor.id, tid: actor.tenantId };
    const ok = await this.db.platform(async (tx) => {
      const rec = p.typ === 'admin'
        ? await tx.platformAdmin.findUnique({ where: { id: p.id } })
        : await tx.user.findUnique({ where: { id: p.id } });
      if (!rec?.passwordHash || rec.status !== 'active' || (rec.lockedUntil && rec.lockedUntil > new Date()) || !(await argon2.verify(rec.passwordHash, password).catch(() => false))) return false;
      if (p.typ === 'admin' && 'mfaEnabled' in rec && !rec.mfaEnabled) return true;
      return this.verifySecondFactor(tx, p, { code });
    });
    await this.audit.record({ action: ok ? 'auth.step_up' : 'auth.step_up_failed', tenantId: p.tid, objectType: p.typ, objectId: p.id }, actor, meta);
    if (!ok) {
      await this.registerFailure(p);
      throw unauthorized('step_up_failed', 'Step-up verification failed');
    }
    return { stepUpToken: this.tokens.sign({ sub: p.id, typ: p.typ, tid: p.tid }, 'step-up'), expiresIn: 300 };
  }

  /** Throws unless the step-up token is valid and belongs to this actor. */
  requireStepUp(actor: Actor, stepUpToken: string | undefined) {
    if (!stepUpToken) throw forbidden('step_up_required', 'This action requires step-up re-authentication');
    let c;
    try {
      c = this.tokens.verify(stepUpToken, 'step-up');
    } catch {
      throw forbidden('step_up_required', 'Step-up token invalid or expired');
    }
    if (c.sub !== actor.id || c.typ !== actor.type) throw forbidden('step_up_required', 'Step-up token does not belong to you');
  }

  async acceptInvite(token: string, password: string, meta: AuditMeta) {
    return this.db.platform(async (tx) => {
      const a = await tx.platformAdmin.findUnique({ where: { inviteTokenHash: sha256(token) } });
      if (!a || a.status !== 'invited' || !a.inviteExpiresAt || a.inviteExpiresAt < new Date()) {
        throw badRequest('invalid_invite', 'Invite is invalid or expired');
      }
      const activated = await tx.platformAdmin.updateMany({
        where: { id: a.id, status: 'invited', inviteTokenHash: sha256(token), inviteExpiresAt: { gt: new Date() } },
        data: { passwordHash: await hashPassword(password), status: 'active', inviteTokenHash: null, inviteExpiresAt: null },
      });
      if (activated.count !== 1) throw badRequest('invalid_invite', 'Invite is invalid, expired or already completed');
      await this.audit.record({ action: 'platform.admin.invite_accepted', objectType: 'admin', objectId: a.id }, { type: 'admin', id: a.id }, meta, tx);
      return { email: a.email };
    });
  }
}
