import * as argon2 from 'argon2';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant, totp, uniq } from './helpers';

describe('platform admin creation without email', () => {
  let t: TestApp;
  let sa: string;
  const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });
  const credentials = () => ({ name: 'New administrator', email: `${uniq('admin')}@example.test`, password: `Admin-${uniq('password')}` });
  beforeAll(async () => {
    t = await createTestApp();
    sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
  });
  afterAll(() => t.close());

  it('creates an active admin with three fields even when mail is unavailable; full MFA sign-in works', async () => {
    const b = credentials();
    const mailCount = t.mailer.sent.length;
    t.mailer.failNext = true;
    const created = (await t.http().post(api('/platform/admins/create')).set(bearer(sa)).send({
      ...b, email: `  ${b.email.toUpperCase()}  `, name: `  ${b.name}  `,
    }).expect(201)).body;
    expect(created).toMatchObject({ name: b.name, email: b.email, status: 'active', mfaEnrolled: false, roles: [{ name: 'Onboarding Admin' }] });
    expect(t.mailer.sent).toHaveLength(mailCount);
    expect(t.mailer.failNext).toBe(true); // no attempt to send a message
    t.mailer.failNext = false;
    const row = await t.owner.platformAdmin.findUniqueOrThrow({ where: { id: created.id } });
    expect(row.passwordHash).toMatch(/^\$argon2id\$/);
    expect(await argon2.verify(row.passwordHash!, b.password)).toBe(true);
    expect(row.inviteTokenHash).toBeNull();
    expect(row.inviteExpiresAt).toBeNull();
    const event = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'platform.admin.created', objectId: row.id } });
    expect(JSON.stringify([created, event])).not.toContain(b.password);
    expect(JSON.stringify([created, event])).not.toContain(row.passwordHash);

    await t.http().post(api('/auth/login')).send({ email: b.email, password: 'wrong' }).expect(401);
    const login = (await t.http().post(api('/auth/login')).send({ email: b.email, password: b.password }).expect(200)).body;
    expect(login.status).toBe('mfa_enrollment_required');
    await t.http().get(api('/platform/admins')).set(bearer(login.enrollmentToken)).expect(401);
    const enrollment = (await t.http().post(api('/me/mfa/enroll')).set(bearer(login.enrollmentToken)).expect(200)).body;
    await t.http().post(api('/me/mfa/confirm')).set(bearer(login.enrollmentToken)).send({ code: totp(enrollment.secret) }).expect(200);
    const challenge = (await t.http().post(api('/auth/login')).send({ email: b.email, password: b.password }).expect(200)).body;
    expect(challenge.status).toBe('mfa_required');
    const tokens = (await t.http().post(api('/auth/mfa/verify')).send({ challengeToken: challenge.challengeToken, code: totp(enrollment.secret, 1) }).expect(200)).body;
    expect((await t.http().get(api('/me')).set(bearer(tokens.accessToken)).expect(200)).body.roles).toEqual(['Onboarding Admin']);
  });

  it('activates a pending or expired invite, preserves roles, invalidates its link and refuses to reset active credentials', async () => {
    const b = credentials();
    const role = await t.owner.platformRole.findUniqueOrThrow({ where: { name: 'Platform Auditor' } });
    const invited = (await t.http().post(api('/platform/admins')).set(bearer(sa)).send({ name: b.name, email: b.email, roleIds: [role.id] }).expect(201)).body;
    const inviteToken = t.mailer.lastTokenFor(b.email);
    await t.owner.platformAdmin.update({ where: { id: invited.id }, data: { inviteExpiresAt: new Date(0) } });
    const mailCount = t.mailer.sent.length;
    const active = (await t.http().post(api(`/platform/admins/${invited.id}/activate`)).set(bearer(sa)).send({ password: b.password }).expect(200)).body;
    expect(active).toMatchObject({ id: invited.id, email: b.email, status: 'active', roles: invited.roles });
    expect(t.mailer.sent).toHaveLength(mailCount);
    await t.http().post(api('/auth/accept-invite')).send({ token: inviteToken, password: b.password }).expect(400);
    expect((await t.http().post(api('/auth/login')).send({ email: b.email, password: b.password }).expect(200)).body.status).toBe('mfa_enrollment_required');
    const hash = (await t.owner.platformAdmin.findUniqueOrThrow({ where: { id: invited.id } })).passwordHash;
    await t.http().post(api(`/platform/admins/${invited.id}/activate`)).set(bearer(sa)).send({ password: `Different-${uniq()}` }).expect(409);
    expect((await t.owner.platformAdmin.findUniqueOrThrow({ where: { id: invited.id } })).passwordHash).toBe(hash);
    const event = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'platform.admin.activated', objectId: invited.id } });
    expect(event.before).toMatchObject({ status: 'invited' });
    expect(event.after).toMatchObject({ status: 'active' });
    expect(JSON.stringify(event)).not.toContain(b.password);
    await t.owner.platformAdmin.update({ where: { id: invited.id }, data: { status: 'disabled' } });
    await t.http().post(api(`/platform/admins/${invited.id}/activate`)).set(bearer(sa)).send({ password: b.password }).expect(409);
  });

  it('refuses weak passwords, invalid fields, duplicate emails and restaurant identities', async () => {
    const b = credentials();
    for (const invalid of [{ ...b, password: 'short' }, { ...b, email: 'invalid' }, { ...b, name: '  ' }]) {
      await t.http().post(api('/platform/admins/create')).set(bearer(sa)).send(invalid).expect(400);
    }
    await t.http().post(api('/platform/admins/create')).set(bearer(sa)).send(b).expect(201);
    await t.http().post(api('/platform/admins/create')).set(bearer(sa)).send(b).expect(409);
    const restaurant = await onboardRestaurant(t, sa);
    const owner = await t.owner.user.findUniqueOrThrow({ where: { id: restaurant.ownerUserId } });
    await t.http().post(api('/platform/admins/create')).set(bearer(sa)).send({ ...credentials(), email: owner.email }).expect(409);
  });

  it('enforces create authority and prevents role escalation for creation and activation', async () => {
    const auditor = await createAdmin(t, ['Platform Auditor']);
    const auditorToken = (await loginAdmin(t, auditor)).accessToken;
    await t.http().post(api('/platform/admins/create')).set(bearer(auditorToken)).send(credentials()).expect(403);
    const limited = await createAdmin(t, ['Onboarding Admin']);
    const creatorRole = await t.owner.platformRole.create({ data: { name: uniq('Creator'), permissions: ['platform.admin.invite'] } });
    await t.owner.platformAdminRole.create({ data: { adminId: limited.id, roleId: creatorRole.id } });
    const limitedToken = (await loginAdmin(t, limited)).accessToken;
    await t.http().post(api('/platform/admins/create')).set(bearer(limitedToken)).send(credentials()).expect(201);
    const superRole = await t.owner.platformRole.findUniqueOrThrow({ where: { name: 'Super Admin' } });
    await t.http().post(api('/platform/admins/create')).set(bearer(limitedToken)).send({ ...credentials(), roleIds: [superRole.id] }).expect(403);
    const invited = (await t.http().post(api('/platform/admins')).set(bearer(sa)).send({ ...credentials(), roleIds: [superRole.id] }).expect(201)).body;
    await t.http().post(api(`/platform/admins/${invited.id}/activate`)).set(bearer(limitedToken)).send({ password: credentials().password }).expect(403);
  });

  it('concurrent creation with the same email results in exactly one account', async () => {
    const b = credentials();
    const results = await Promise.all([0, 1].map(() => t.http().post(api('/platform/admins/create')).set(bearer(sa)).send(b)));
    expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
    expect(await t.owner.platformAdmin.count({ where: { email: b.email } })).toBe(1);
  });

  it('an invite link racing with direct activation cannot overwrite the winner’s password', async () => {
    const b = credentials();
    const role = await t.owner.platformRole.findUniqueOrThrow({ where: { name: 'Onboarding Admin' } });
    const invited = (await t.http().post(api('/platform/admins')).set(bearer(sa)).send({ email: b.email, name: b.name, roleIds: [role.id] }).expect(201)).body;
    const token = t.mailer.lastTokenFor(b.email);
    const otherPassword = `Invite-${uniq()}`;
    const results = await Promise.all([
      t.http().post(api(`/platform/admins/${invited.id}/activate`)).set(bearer(sa)).send({ password: b.password }),
      t.http().post(api('/auth/accept-invite')).send({ token, password: otherPassword }),
    ]);
    expect(results.filter((r) => r.status === 200)).toHaveLength(1);
    const row = await t.owner.platformAdmin.findUniqueOrThrow({ where: { id: invited.id } });
    expect(await argon2.verify(row.passwordHash!, results[0].status === 200 ? b.password : otherPassword)).toBe(true);
    expect(row.inviteTokenHash).toBeNull();
  });
});
