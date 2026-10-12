import { Body, Controller, Get, Headers, HttpCode, Ip, Post, Req } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import { loadEnv } from '../config/env';
import type { Actor, AppRequest } from '../common/actor';
import { CurrentActor } from '../common/actor';
import { AllowEnrollmentToken, AuthenticatedOnly, Public } from '../common/decorators';
import { badRequest } from '../common/errors';
import { zbody } from '../common/validation';
import { DbService } from '../db/db.service';
import { AuthService } from './auth.service';

// Resolved per request so the configured limit (AUTH_RATE_LIMIT_PER_MIN, default 10/min/IP) always applies.
const authLimit = () => ({ default: { limit: () => loadEnv().AUTH_RATE_LIMIT_PER_MIN, ttl: 60_000 } });

const LoginBody = z.object({ email: z.string().email(), password: z.string().min(1).max(256) });
const MfaVerifyBody = z
  .object({ challengeToken: z.string().min(1), code: z.string().optional(), recoveryCode: z.string().optional() })
  .refine((b) => !!b.code !== !!b.recoveryCode, 'provide exactly one of code or recoveryCode');
const RefreshBody = z.object({ refreshToken: z.string().min(1) });
const StepUpBody = z.object({ password: z.string().min(1), code: z.string().regex(/^\d{6}$/) });
const ConfirmBody = z.object({ code: z.string().regex(/^\d{6}$/) });
const AcceptInviteBody = z.object({ token: z.string().min(1), password: z.string().min(12).max(256) });

const meta = (req: AppRequest, ip: string, ua?: string) => ({ ip, userAgent: ua, sessionId: req.actor?.sessionId });

@ApiTags('auth')
@Controller()
export class AuthController {
  constructor(private auth: AuthService, private db: DbService) {}

  @Public()
  @Throttle(authLimit())
  @Post('auth/login')
  @HttpCode(200)
  login(@Body(zbody(LoginBody)) b: z.infer<typeof LoginBody>, @Req() req: AppRequest, @Ip() ip: string, @Headers('user-agent') ua?: string) {
    return this.auth.login(b.email, b.password, meta(req, ip, ua));
  }

  @Public()
  @Throttle(authLimit())
  @Post('auth/mfa/verify')
  @HttpCode(200)
  mfaVerify(@Body(zbody(MfaVerifyBody)) b: z.infer<typeof MfaVerifyBody>, @Req() req: AppRequest, @Ip() ip: string, @Headers('user-agent') ua?: string) {
    return this.auth.mfaVerify(b.challengeToken, b, meta(req, ip, ua));
  }

  @Public()
  @Throttle(authLimit())
  @Post('auth/refresh')
  @HttpCode(200)
  refresh(@Body(zbody(RefreshBody)) b: z.infer<typeof RefreshBody>, @Req() req: AppRequest, @Ip() ip: string, @Headers('user-agent') ua?: string) {
    return this.auth.refresh(b.refreshToken, meta(req, ip, ua));
  }

  @AuthenticatedOnly()
  @Post('auth/logout')
  @HttpCode(204)
  async logout(@Body(zbody(RefreshBody)) b: z.infer<typeof RefreshBody>, @CurrentActor() actor: Actor, @Req() req: AppRequest, @Ip() ip: string) {
    await this.auth.logout(b.refreshToken, actor, meta(req, ip));
  }

  @ApiBearerAuth()
  @AuthenticatedOnly()
  @Throttle(authLimit())
  @Post('auth/step-up')
  @HttpCode(200)
  stepUp(@Body(zbody(StepUpBody)) b: z.infer<typeof StepUpBody>, @CurrentActor() actor: Actor, @Req() req: AppRequest, @Ip() ip: string) {
    return this.auth.stepUp(actor, b.password, b.code, meta(req, ip));
  }

  @Public()
  @Throttle(authLimit())
  @Post('auth/accept-invite')
  @HttpCode(200)
  acceptInvite(@Body(zbody(AcceptInviteBody)) b: z.infer<typeof AcceptInviteBody>, @Req() req: AppRequest, @Ip() ip: string) {
    return this.auth.acceptInvite(b.token, b.password, meta(req, ip));
  }

  @ApiBearerAuth()
  @AuthenticatedOnly()
  @Get('me')
  async me(@CurrentActor() a: Actor) {
    const profile = await this.db.platform(async (tx) =>
      a.type === 'admin'
        ? tx.platformAdmin.findUnique({ where: { id: a.id }, select: { id: true, email: true, name: true, mfa: { select: { enrolledAt: true } } } })
        : tx.user.findUnique({ where: { id: a.id }, select: { id: true, email: true, name: true, tenantId: true, mfa: { select: { enrolledAt: true } } } }),
    );
    return {
      type: a.type, ...profile, mfaEnrolled: !!profile?.mfa?.enrolledAt, mfa: undefined,
      roles: a.roles, permissions: [...a.permissions].sort(), branchIds: a.branchIds,
    };
  }

  @ApiBearerAuth()
  @AuthenticatedOnly()
  @AllowEnrollmentToken()
  @Throttle(authLimit())
  @Post('me/mfa/enroll')
  @HttpCode(200)
  async enroll(@CurrentActor() a: Actor) {
    const email = await this.db.platform(async (tx) =>
      a.type === 'admin'
        ? (await tx.platformAdmin.findUnique({ where: { id: a.id } }))?.email
        : (await tx.user.findUnique({ where: { id: a.id } }))?.email,
    );
    return this.auth.enrollStart({ typ: a.type, id: a.id, tid: a.tenantId }, email ?? a.id);
  }

  @ApiBearerAuth()
  @AuthenticatedOnly()
  @AllowEnrollmentToken()
  @Throttle(authLimit())
  @Post('me/mfa/confirm')
  @HttpCode(200)
  async confirm(@Body(zbody(ConfirmBody)) b: z.infer<typeof ConfirmBody>, @CurrentActor() a: Actor, @Req() req: AppRequest, @Ip() ip: string) {
    const p = { typ: a.type, id: a.id, tid: a.tenantId };
    const { recoveryCodes } = await this.auth.enrollConfirm(p, b.code, meta(req, ip));
    // First-login enrolment finishes the sign-in: hand out real tokens now.
    const tokens = a.tokenAudience === 'mfa-enroll' ? await this.auth.issueTokens(p, meta(req, ip)) : undefined;
    if (!recoveryCodes) throw badRequest('mfa_error', 'Enrolment failed');
    return { recoveryCodes, ...(tokens ? { tokens } : {}) };
  }
}
