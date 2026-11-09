/**
 * Super Admin support for a restaurant's owner (password reset link, MFA reset) and cold-storage archiving of a
 * restaurant that has real rows (branch `seq` BigInt cursors broke JSON serialisation → 500 on every archive).
 */
import { gunzipSync } from 'zlib';
import { TestApp, api, createAdmin, createTestApp, login, loginAdmin, onboardRestaurant, totp } from './helpers';

describe('owner support and archiving', () => {
  let t: TestApp;
  let sa: string;
  let saAdmin: Awaited<ReturnType<typeof createAdmin>>;
  let stepTok: string; // a step-up token is valid for 5 minutes, so one serves the whole file
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    saAdmin = await createAdmin(t, ['Super Admin']);
    sa = (await loginAdmin(t, saAdmin)).accessToken;
    stepTok = (await t.http().post(api('/auth/step-up')).set(bearer(sa)).send({ password: saAdmin.password, code: totp(saAdmin.secret, 1) }).expect(200)).body.stepUpToken;
  });
  afterAll(() => t.close());

  it('archives a suspended restaurant with branches (BigInt seq) and keeps credentials out of the bundle', async () => {
    const r = await onboardRestaurant(t, sa);
    await t.http().post(api(`/restaurants/${r.tenantId}/status`)).set(bearer(sa)).send({ action: 'suspend', reason: 'test suspend' }).expect(200);
    const res = await t.http().post(api(`/restaurants/${r.tenantId}/archive`)).set(bearer(sa)).send({ reason: 'test archive' }).expect(200);
    expect(res.body).toMatchObject({ status: 'archived', counts: expect.objectContaining({ branches: 1, users: 1 }) });

    const dl = await t.http().get(api(`/restaurants/${r.tenantId}/archive/download`)).set(bearer(sa)).buffer(true)
      .parse((resp, cb) => { const chunks: Buffer[] = []; resp.on('data', (c: Buffer) => chunks.push(c)); resp.on('end', () => cb(null, Buffer.concat(chunks))); })
      .expect(200);
    const doc = JSON.parse(gunzipSync(dl.body as Buffer).toString('utf8'));
    expect(typeof doc.data.branches[0].seq).toBe('string');
    const user = doc.data.users[0];
    expect(user.email).toBe(r.ownerEmail);
    expect(user).not.toHaveProperty('passwordHash');
    expect(user).not.toHaveProperty('pinHash');
  });

  it('sends the owner a one-time password reset link (step-up + audit) that sets a new password and ends old sessions', async () => {
    const r = await onboardRestaurant(t, sa);
    const url = api(`/restaurants/${r.tenantId}/owner/password-reset`);
    await t.http().post(url).set(bearer(sa)).send({ reason: 'owner forgot password' }).expect(403); // no step-up
    await t.http().post(url).set(bearer(r.ownerToken)).send({ reason: 'self' }).expect(403); // owners cannot use it

    const owner0 = (await t.http().get(api(`/restaurants/${r.tenantId}/owner`)).set(bearer(sa)).expect(200)).body;
    expect(owner0).toMatchObject({ email: r.ownerEmail, mfaEnrolled: false, passwordResetPendingUntil: null });

    const sent = (await t.http().post(url).set(bearer(sa)).set('X-Step-Up-Token', stepTok).send({ reason: 'owner forgot password' }).expect(200)).body;
    expect(sent).toMatchObject({ ownerEmail: r.ownerEmail, emailed: true });
    const token = t.mailer.lastTokenFor(r.ownerEmail);
    expect(sent.link).toContain(`#/reset-password?token=${token}`);
    expect((await t.http().get(api(`/restaurants/${r.tenantId}/owner`)).set(bearer(sa)).expect(200)).body.passwordResetPendingUntil).not.toBeNull();

    // a password-reset link is not a PIN link
    await t.http().post(api('/auth/pin-link/check')).send({ token }).expect(400);
    expect((await t.http().post(api('/auth/password-link/check')).send({ token }).expect(200)).body).toMatchObject({ email: r.ownerEmail });
    await t.http().post(api('/auth/password-link/complete')).send({ token, password: 'short' }).expect(400);

    const refresh = (await login(t, r.ownerEmail, r.password)).refreshToken;
    const newPassword = 'Brand-New-Owner-Pass-1';
    await t.http().post(api('/auth/password-link/complete')).send({ token, password: newPassword }).expect(200);
    await t.http().post(api('/auth/password-link/complete')).send({ token, password: newPassword }).expect(400); // single use
    await t.http().post(api('/auth/login')).send({ email: r.ownerEmail, password: r.password }).expect(401);
    await login(t, r.ownerEmail, newPassword);
    await t.http().post(api('/auth/refresh')).send({ refreshToken: refresh }).expect(401); // old session revoked

    const actions = (await t.owner.auditEvent.findMany({ where: { tenantId: r.tenantId, action: { startsWith: 'restaurant.owner_password_reset' } } })).map((e) => e.action);
    expect(actions.sort()).toEqual(['restaurant.owner_password_reset_completed', 'restaurant.owner_password_reset_sent']);
  });

  it('resets the owner MFA with step-up; the owner then signs in with the password alone', async () => {
    const r = await onboardRestaurant(t, sa);
    const url = api(`/restaurants/${r.tenantId}/owner/mfa/reset`);
    // nothing to reset yet
    await t.http().post(url).set(bearer(sa)).set('X-Step-Up-Token', stepTok).send({ reason: 'lost phone' }).expect(409);

    const enrol = (await t.http().post(api('/me/mfa/enroll')).set(bearer(r.ownerToken)).expect(200)).body;
    const secret = enrol.secret as string;
    await t.http().post(api('/me/mfa/confirm')).set(bearer(r.ownerToken)).send({ code: totp(secret) }).expect(200);
    expect((await t.http().post(api('/auth/login')).send({ email: r.ownerEmail, password: r.password }).expect(200)).body.status).toBe('mfa_required');

    await t.http().post(url).set(bearer(sa)).send({ reason: 'lost phone' }).expect(403); // step-up required
    const done = (await t.http().post(url).set(bearer(sa)).set('X-Step-Up-Token', stepTok).send({ reason: 'lost phone' }).expect(200)).body;
    expect(done).toMatchObject({ mfaReset: true, notified: r.ownerEmail });
    expect((await t.http().post(api('/auth/login')).send({ email: r.ownerEmail, password: r.password }).expect(200)).body.status).toBe('ok');
    expect(await t.owner.auditEvent.count({ where: { tenantId: r.tenantId, action: 'restaurant.owner_mfa_reset' } })).toBe(1);
  });
});
