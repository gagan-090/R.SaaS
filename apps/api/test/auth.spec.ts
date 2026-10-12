/**
 * M2 — auth, RBAC, MFA, audit. Covers AC-03 (MFA reset) and AC-11 groundwork (auditor gets 403 on every write route).
 */
import { authenticator } from 'otplib';
import { TestApp, addStaff, api, createAdmin, createTestApp, fillParams, listRoutes, loginAdmin, onboardRestaurant, totp, uniq } from './helpers';

describe('auth, MFA, RBAC, audit', () => {
  let t: TestApp;
  beforeAll(async () => {
    t = await createTestApp();
  });
  afterAll(() => t.close());

  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  describe('login / refresh / logout', () => {
    it('first admin login forces MFA enrolment, then issues tokens and 10 recovery codes', async () => {
      const a = await createAdmin(t, ['Super Admin'], { mfa: false });
      const r1 = await t.http().post(api('/auth/login')).send({ email: a.email, password: a.password }).expect(200);
      expect(r1.body.status).toBe('mfa_enrollment_required');
      // the enrolment token cannot be used as an access token
      await t.http().get(api('/platform/admins')).set(bearer(r1.body.enrollmentToken)).expect(401);
      const e = await t.http().post(api('/me/mfa/enroll')).set(bearer(r1.body.enrollmentToken)).expect(200);
      expect(e.body.otpauthUrl).toMatch(/^otpauth:\/\/totp\//);
      await t.http().post(api('/me/mfa/confirm')).set(bearer(r1.body.enrollmentToken)).send({ code: '000000' }).expect(400);
      const c = await t.http().post(api('/me/mfa/confirm')).set(bearer(r1.body.enrollmentToken)).send({ code: authenticator.generate(e.body.secret) }).expect(200);
      expect(c.body.recoveryCodes).toHaveLength(10);
      expect(c.body.tokens.accessToken).toBeTruthy();
      // MFA secret is encrypted at rest
      const row = await t.owner.mFAEnrollment.findFirstOrThrow({ where: { adminId: a.id } });
      expect(row.totpSecretEncrypted).not.toContain(e.body.secret);
      expect(row.recoveryCodeHashes).not.toContain(c.body.recoveryCodes[0]);
      // next login asks for the second factor; a recovery code works exactly once
      const r2 = await t.http().post(api('/auth/login')).send({ email: a.email, password: a.password }).expect(200);
      expect(r2.body.status).toBe('mfa_required');
      await t.http().post(api('/auth/mfa/verify')).send({ challengeToken: r2.body.challengeToken, recoveryCode: c.body.recoveryCodes[0] }).expect(200);
      const r3 = await t.http().post(api('/auth/login')).send({ email: a.email, password: a.password }).expect(200);
      await t.http().post(api('/auth/mfa/verify')).send({ challengeToken: r3.body.challengeToken, recoveryCode: c.body.recoveryCodes[0] }).expect(401);
    });

    it('rejects bad passwords without revealing whether the email exists', async () => {
      const a = await createAdmin(t, ['Super Admin']);
      const bad = await t.http().post(api('/auth/login')).send({ email: a.email, password: 'wrong-password' }).expect(401);
      const none = await t.http().post(api('/auth/login')).send({ email: `${uniq()}@nowhere.test`, password: 'x' }).expect(401);
      expect(bad.body.code).toBe('invalid_credentials');
      expect(none.body.code).toBe('invalid_credentials');
    });

    it('locks the account for 15 minutes after 5 failed logins', async () => {
      const a = await createAdmin(t, ['Super Admin']);
      for (let i = 0; i < 5; i++) await t.http().post(api('/auth/login')).send({ email: a.email, password: 'nope' }).expect(401);
      const r = await t.http().post(api('/auth/login')).send({ email: a.email, password: a.password }).expect(401);
      expect(r.body.code).toBe('account_locked');
    });

    it('rotates refresh tokens and revokes the family when a rotated token is reused', async () => {
      const a = await createAdmin(t, ['Super Admin']);
      const p1 = await loginAdmin(t, a);
      const p2 = (await t.http().post(api('/auth/refresh')).send({ refreshToken: p1.refreshToken }).expect(200)).body;
      expect(p2.refreshToken).not.toBe(p1.refreshToken);
      const reuse = await t.http().post(api('/auth/refresh')).send({ refreshToken: p1.refreshToken }).expect(401);
      expect(reuse.body.code).toBe('refresh_reused');
      // the whole family is now dead, including the newest token
      await t.http().post(api('/auth/refresh')).send({ refreshToken: p2.refreshToken }).expect(401);
      // refresh tokens are stored hashed
      expect(await t.owner.refreshToken.count({ where: { tokenHash: p2.refreshToken } })).toBe(0);
    });

    it('logout revokes the refresh token', async () => {
      const a = await createAdmin(t, ['Super Admin']);
      const p = await loginAdmin(t, a);
      await t.http().post(api('/auth/logout')).set(bearer(p.accessToken)).send({ refreshToken: p.refreshToken }).expect(204);
      await t.http().post(api('/auth/refresh')).send({ refreshToken: p.refreshToken }).expect(401);
    });

    it('rejects tokens signed with another secret or algorithm', async () => {
      const forged = Buffer.from('{"alg":"none"}').toString('base64url') + '.' + Buffer.from('{"sub":"x","typ":"admin","aud":"access"}').toString('base64url') + '.';
      await t.http().get(api('/me')).set(bearer(forged)).expect(401);
      await t.http().get(api('/me')).expect(401);
    });
  });

  describe('AC-03 MFA reset', () => {
    it('unauthorised admin gets 403; authorised admin without step-up is rejected; a valid reset is audited and notified', async () => {
      const target = await createAdmin(t, ['Onboarding Admin']);
      const weak = await createAdmin(t, ['Onboarding Admin']); // lacks platform.mfa.reset
      const sa = await createAdmin(t, ['Super Admin']);
      const weakTok = (await loginAdmin(t, weak)).accessToken;
      const saTok = (await loginAdmin(t, sa)).accessToken;
      const url = api(`/platform/admins/${target.id}/mfa/reset`);

      const r1 = await t.http().post(url).set(bearer(weakTok)).send({ reason: 'lost phone' }).expect(403);
      expect(r1.body.code).toBe('missing_permission');

      const r2 = await t.http().post(url).set(bearer(saTok)).send({ reason: 'lost phone' }).expect(403);
      expect(r2.body.code).toBe('step_up_required');

      // a step-up token from a different admin is not accepted
      const otherStep = await createAdmin(t, ['Super Admin']);
      const otherTok = (await loginAdmin(t, otherStep)).accessToken;
      const foreign = (await t.http().post(api('/auth/step-up')).set(bearer(otherTok)).send({ password: otherStep.password, code: totp(otherStep.secret, 1) }).expect(200)).body.stepUpToken;
      await t.http().post(url).set(bearer(saTok)).set('X-Step-Up-Token', foreign).send({ reason: 'lost phone' }).expect(403);

      // wrong password on step-up fails
      await t.http().post(api('/auth/step-up')).set(bearer(saTok)).send({ password: 'wrong', code: totp(sa.secret, 1) }).expect(401);
      const step = (await t.http().post(api('/auth/step-up')).set(bearer(saTok)).send({ password: sa.password, code: totp(sa.secret, 1) }).expect(200)).body.stepUpToken;
      const ok = await t.http().post(url).set(bearer(saTok)).set('X-Step-Up-Token', step).send({ reason: 'lost phone' }).expect(200);
      expect(ok.body).toMatchObject({ mfaReset: true, notified: target.email });

      const ev = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'platform.admin.mfa_reset', objectId: target.id } });
      expect(ev).toMatchObject({ actorId: sa.id, reason: 'lost phone' });
      expect(await t.owner.notification.count({ where: { recipient: target.email, type: 'mfa_reset' } })).toBe(1);
      expect(t.mailer.sent.some((m) => m.to === target.email && /reset/i.test(m.subject))).toBe(true);
      // target must enrol again on next login
      const relog = await t.http().post(api('/auth/login')).send({ email: target.email, password: target.password }).expect(200);
      expect(relog.body.status).toBe('mfa_enrollment_required');
      // a reason is mandatory
      await t.http().post(api(`/platform/admins/${weak.id}/mfa/reset`)).set(bearer(saTok)).set('X-Step-Up-Token', step).send({}).expect(400);
    });

    it('an admin cannot reset their own MFA through the admin route', async () => {
      const sa = await createAdmin(t, ['Super Admin']);
      const tok = (await loginAdmin(t, sa)).accessToken;
      await t.http().post(api(`/platform/admins/${sa.id}/mfa/reset`)).set(bearer(tok)).send({ reason: 'self' }).expect(403);
    });
  });

  describe('platform admin invite & self-escalation', () => {
    it('invites an admin with granular roles; invitee accepts and must enrol MFA', async () => {
      const sa = await createAdmin(t, ['Super Admin']);
      const tok = (await loginAdmin(t, sa)).accessToken;
      const role = (await t.http().get(api('/platform/roles')).set(bearer(tok)).expect(200)).body.find((r: { name: string }) => r.name === 'Platform Auditor');
      const email = `${uniq('inv')}@example.test`;
      await t.http().post(api('/platform/admins')).set(bearer(tok)).send({ email, name: 'Invitee', roleIds: [role.id] }).expect(201);
      const token = t.mailer.lastTokenFor(email);
      const pw = `Invitee-${uniq()}`;
      await t.http().post(api('/auth/accept-invite')).send({ token, password: pw }).expect(200);
      await t.http().post(api('/auth/accept-invite')).send({ token, password: pw }).expect(400);
      const l = await t.http().post(api('/auth/login')).send({ email, password: pw }).expect(200);
      expect(l.body.status).toBe('mfa_enrollment_required');
      expect(await t.owner.auditEvent.count({ where: { action: 'platform.admin.invited', actorId: sa.id } })).toBe(1);
    });

    it('blocks self-escalation and granting permissions the actor does not hold', async () => {
      const onboarding = await createAdmin(t, ['Onboarding Admin', 'Platform Auditor']);
      const sa = await createAdmin(t, ['Super Admin']);
      // give the onboarding admin roles power so we test the subset rule rather than the permission gate
      const rolesPerm = await t.owner.platformRole.create({ data: { name: uniq('RoleAdmin'), permissions: ['platform.admin.roles', 'platform.admin.read'] } });
      await t.owner.platformAdminRole.create({ data: { adminId: onboarding.id, roleId: rolesPerm.id } });
      const tok = (await loginAdmin(t, onboarding)).accessToken;
      const superRole = await t.owner.platformRole.findUniqueOrThrow({ where: { name: 'Super Admin' } });

      const self = await t.http().patch(api(`/platform/admins/${onboarding.id}/roles`)).set(bearer(tok)).send({ roleIds: [superRole.id] }).expect(403);
      expect(self.body.code).toBe('self_escalation');
      const other = await createAdmin(t, ['Platform Auditor']);
      const esc = await t.http().patch(api(`/platform/admins/${other.id}/roles`)).set(bearer(tok)).send({ roleIds: [superRole.id] }).expect(403);
      expect(esc.body.code).toBe('escalation_denied');
      // cannot demote someone more powerful
      const dem = await t.http().patch(api(`/platform/admins/${sa.id}/roles`)).set(bearer(tok)).send({ roleIds: [] }).expect(403);
      expect(dem.body.code).toBe('escalation_denied');
      // can create a role only from permissions held
      await t.http().post(api('/platform/roles')).set(bearer(tok)).send({ name: uniq('r'), permissions: ['platform.mfa.reset'] }).expect(403);
      await t.http().post(api('/platform/roles')).set(bearer(tok)).send({ name: uniq('r'), permissions: ['platform.restaurant.read'] }).expect(201);
      // an allowed change is audited with before/after
      const auditorRole = await t.owner.platformRole.findUniqueOrThrow({ where: { name: 'Platform Auditor' } });
      await t.http().patch(api(`/platform/admins/${other.id}/roles`)).set(bearer(tok)).send({ roleIds: [auditorRole.id] }).expect(200);
      const ev = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'platform.admin.roles_changed', objectId: other.id } });
      expect(ev.before).toBeTruthy();
      expect(ev.after).toBeTruthy();
    });
  });

  describe('audit interceptor', () => {
    it('records actor, tenant, action, object, before/after, reason, session, device and UTC time — never secrets', async () => {
      const sa = await createAdmin(t, ['Super Admin']);
      const tok = (await loginAdmin(t, sa)).accessToken;
      const R = await onboardRestaurant(t, tok);
      await t.http().post(api(`/restaurants/${R.tenantId}/status`)).set(bearer(tok)).set('X-Device-Id', 'portal-test').send({ action: 'suspend', reason: 'unpaid invoice' }).expect(200);
      const ev = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'restaurant.status_changed', tenantId: R.tenantId } });
      expect(ev).toMatchObject({ actorId: sa.id, actorType: 'admin', objectType: 'restaurant', objectId: R.tenantId, reason: 'unpaid invoice', deviceId: 'portal-test' });
      expect(ev.before).toEqual({ status: 'active' });
      expect(ev.after).toEqual({ status: 'suspended' });
      expect(ev.sessionId).toBeTruthy();
      expect(ev.at.getTime()).toBeLessThanOrEqual(Date.now());
      // nothing secret anywhere in the audit log
      const all = JSON.stringify(await t.owner.auditEvent.findMany({ where: { OR: [{ actorId: sa.id }, { tenantId: R.tenantId }] } }));
      expect(all).not.toContain(sa.password);
      expect(all).not.toContain(R.password);
      expect(all).not.toContain(tok);
    });
  });

  describe('AC-11 groundwork: auditor roles get 403 on every write route', () => {
    it('platform auditor and restaurant auditor are refused on every authenticated write route', async () => {
      const sa = await createAdmin(t, ['Super Admin']);
      const saTok = (await loginAdmin(t, sa)).accessToken;
      const R = await onboardRestaurant(t, saTok, 'premium');
      const pa = await createAdmin(t, ['Platform Auditor']);
      const paTok = (await loginAdmin(t, pa)).accessToken;
      const ra = await addStaff(t, R.tenantId, 'auditor');

      const writes = listRoutes(t.app).filter((r) => r.method !== 'GET' && !r.isPublic && !r.authenticatedOnly);
      expect(writes.length).toBeGreaterThan(15);
      const failures: string[] = [];
      for (const r of writes) {
        for (const [who, tok] of [['platform-auditor', paTok], ['restaurant-auditor', ra.token]] as const) {
          const path = fillParams(r.path, R.tenantId);
          const res = await t.http()[r.method.toLowerCase() as 'post'](path).set(bearer(tok)).send({ reason: 'x', name: 'x' });
          if (res.status !== 403) failures.push(`${who} ${r.method} ${r.path} -> ${res.status}`);
        }
      }
      expect(failures).toEqual([]);
      // and the auditors can still read what they are authorised to see
      await t.http().get(api('/platform/audit')).set(bearer(paTok)).expect(200);
      await t.http().get(api('/audit')).set(bearer(ra.token)).expect(200);
    });
  });
});
