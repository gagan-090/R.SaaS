import { TestApp, api, createAdmin, createTestApp, loginAdmin, totp, uniq } from './helpers';

describe('Super Admin per-account MFA policy', () => {
  let t: TestApp;
  let sa: Awaited<ReturnType<typeof createAdmin>>;
  let token: string;
  const bearer = (value: string) => ({ Authorization: `Bearer ${value}` });
  beforeAll(async () => {
    t = await createTestApp();
    sa = await createAdmin(t, ['Super Admin']);
    token = (await loginAdmin(t, sa)).accessToken;
  });
  afterAll(() => t.close());
  async function step() {
    await t.owner.mFAEnrollment.update({ where: { adminId: sa.id }, data: { lastUsedStep: null } });
    return (await t.http().post(api('/auth/step-up')).set(bearer(token)).send({ password: sa.password, code: totp(sa.secret) }).expect(200)).body.stepUpToken as string;
  }
  const policy = (id: string, enabled: boolean, verification: string, actor = token) => t.http().post(api(`/platform/admins/${id}/mfa/policy`))
    .set(bearer(actor)).set('X-Step-Up-Token', verification).send({ enabled, reason: 'Account security policy requested by Super Admin' });

  it('off uses password login; on uses the retained authenticator; both revoke existing sessions and audit the change', async () => {
    const target = await createAdmin(t, ['Platform Auditor']);
    const old = await loginAdmin(t, target);
    const secret = (await t.owner.mFAEnrollment.findUniqueOrThrow({ where: { adminId: target.id } })).totpSecretEncrypted;
    const off = (await policy(target.id, false, await step()).expect(200)).body;
    expect(off).toMatchObject({ mfaEnabled: false, mfaEnrolled: true, sessionsRevoked: true });
    await t.http().get(api('/me')).set(bearer(old.accessToken)).expect(401);
    await t.http().post(api('/auth/refresh')).send({ refreshToken: old.refreshToken }).expect(401);
    const passwordOnly = (await t.http().post(api('/auth/login')).send({ email: target.email, password: target.password }).expect(200)).body;
    expect(passwordOnly.status).toBe('ok');
    expect((await t.http().get(api('/me')).set(bearer(passwordOnly.accessToken)).expect(200)).body.mfaEnabled).toBe(false);
    await policy(target.id, true, await step()).expect(200);
    await t.http().get(api('/me')).set(bearer(passwordOnly.accessToken)).expect(401);
    expect((await t.http().post(api('/auth/login')).send({ email: target.email, password: target.password }).expect(200)).body.status).toBe('mfa_required');
    expect((await t.owner.mFAEnrollment.findUniqueOrThrow({ where: { adminId: target.id } })).totpSecretEncrypted).toBe(secret);
    const events = await t.owner.auditEvent.findMany({ where: { objectId: target.id, action: 'platform.admin.mfa_policy_changed' }, orderBy: { at: 'asc' } });
    expect(events).toHaveLength(2);
    expect(events[0].before).toEqual({ mfaEnabled: true });
    expect(events[0].after).toEqual({ mfaEnabled: false });
    expect(events[1].after).toEqual({ mfaEnabled: true });
    expect(events[0].actorId).toBe(sa.id);
    expect(JSON.stringify(events)).not.toContain(secret);
  });

  it('an account without an authenticator must enrol when MFA is turned on', async () => {
    const target = await createAdmin(t, ['Onboarding Admin'], { mfa: false });
    await policy(target.id, false, await step()).expect(200);
    expect((await t.http().post(api('/auth/login')).send({ email: target.email, password: target.password }).expect(200)).body.status).toBe('ok');
    await policy(target.id, true, await step()).expect(200);
    expect((await t.http().post(api('/auth/login')).send({ email: target.email, password: target.password }).expect(200)).body.status).toBe('mfa_enrollment_required');
  });

  it('only the actual Super Admin role can change policies; fresh identity confirmation and reason are required', async () => {
    const target = await createAdmin(t, ['Platform Auditor']);
    await policy(target.id, false, '').expect(403);
    const delegated = await createAdmin(t, ['Platform Auditor']);
    const role = await t.owner.platformRole.create({ data: { name: uniq('MfaManager'), permissions: ['platform.mfa.reset'] } });
    await t.owner.platformAdminRole.create({ data: { adminId: delegated.id, roleId: role.id } });
    const delegatedToken = (await loginAdmin(t, delegated)).accessToken;
    const otherStep = (await t.http().post(api('/auth/step-up')).set(bearer(delegatedToken)).send({ password: delegated.password, code: totp(delegated.secret, 1) }).expect(200)).body.stepUpToken;
    expect((await policy(target.id, false, otherStep, delegatedToken).expect(403)).body.code).toBe('super_admin_only');
    await policy(target.id, false, otherStep).expect(403);
    const proof = await step();
    await t.http().post(api(`/platform/admins/${target.id}/mfa/policy`)).set(bearer(token)).set('X-Step-Up-Token', proof).send({ enabled: false, reason: '' }).expect(400);
    await t.http().post(api('/auth/step-up')).set(bearer(token)).send({ password: 'wrong' }).expect(401);
    expect((await t.owner.platformAdmin.findUniqueOrThrow({ where: { id: target.id } })).mfaEnabled).toBe(true);
  });

  it('a concurrent refresh cannot keep a password-only session alive after MFA is enabled', async () => {
    const target = await createAdmin(t, ['Platform Auditor']);
    await policy(target.id, false, await step()).expect(200);
    const login = (await t.http().post(api('/auth/login')).send({ email: target.email, password: target.password }).expect(200)).body;
    const verification = await step();
    const [changed, refreshed] = await Promise.all([
      policy(target.id, true, verification),
      t.http().post(api('/auth/refresh')).send({ refreshToken: login.refreshToken }),
    ]);
    expect(changed.status).toBe(200);
    expect([200, 401]).toContain(refreshed.status);
    if (refreshed.status === 200) await t.http().get(api('/me')).set(bearer(refreshed.body.accessToken)).expect(401);
    await t.http().get(api('/me')).set(bearer(login.accessToken)).expect(401);
  });

  it('Super Admins can turn their own MFA off and back on, using password confirmation while it is off', async () => {
    await policy(sa.id, false, await step()).expect(200);
    await t.http().get(api('/me')).set(bearer(token)).expect(401);
    const login = (await t.http().post(api('/auth/login')).send({ email: sa.email, password: sa.password }).expect(200)).body;
    expect(login.status).toBe('ok');
    const confirmation = (await t.http().post(api('/auth/step-up')).set(bearer(login.accessToken)).send({ password: sa.password }).expect(200)).body;
    await policy(sa.id, true, confirmation.stepUpToken, login.accessToken).expect(200);
    await t.http().get(api('/me')).set(bearer(login.accessToken)).expect(401);
    expect((await t.http().post(api('/auth/login')).send({ email: sa.email, password: sa.password }).expect(200)).body.status).toBe('mfa_required');
  });
});
