/** Restaurants awaiting the owner's email confirmation: visible to the Super Admin, resend with a fresh link, cancel. */
import { TestApp, api, createAdmin, createTestApp, loginAdmin, uniq } from './helpers';

describe('pending registrations', () => {
  let t: TestApp;
  let sa: string;
  let auditor: string;
  const auth = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const register = async (name: string) => {
    const ownerEmail = `${uniq('o')}@example.test`;
    const r = (await t.http().post(api('/restaurants')).set(auth(sa)).send({ ownerEmail, ownerName: 'Owner', restaurantName: name, planCode: 'professional' }).expect(201)).body;
    return { ...r, ownerEmail };
  };

  beforeAll(async () => {
    t = await createTestApp();
    sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    auditor = (await loginAdmin(t, await createAdmin(t, ['Platform Auditor']))).accessToken;
  });
  afterAll(() => t.close());

  it('a registered restaurant shows in the awaiting queue with its plan, send count and expiry', async () => {
    const name = uniq('Awaiting Diner');
    const r = await register(name);
    const q = (await t.http().get(api(`/restaurants/registrations?q=${encodeURIComponent(name)}`)).set(auth(auditor)).expect(200)).body;
    expect(q.counts.awaiting).toBeGreaterThanOrEqual(1);
    expect(q.items).toEqual([expect.objectContaining({ id: r.registrationId, restaurantName: name, ownerEmail: r.ownerEmail, planName: 'Professional', state: 'awaiting', sendCount: 1 })]);
    expect(new Date(q.items[0].expiresAt).getTime()).toBeGreaterThan(Date.now() + 71 * 3600_000);
  });

  it('resend issues a new link (the old one stops working) and counts the send', async () => {
    const r = await register(uniq('Resend Cafe'));
    const oldToken = t.mailer.lastTokenFor(r.ownerEmail);
    const res = (await t.http().post(api(`/restaurants/registrations/${r.registrationId}/resend`)).set(auth(sa)).expect(200)).body;
    expect(res).toMatchObject({ emailSent: true, sendCount: 2 });
    const newToken = t.mailer.lastTokenFor(r.ownerEmail);
    expect(newToken).not.toBe(oldToken);
    await t.http().post(api('/restaurants/verify-email')).send({ token: oldToken, password: `Pw-${uniq('a')}-1` }).expect(400);
    await t.http().post(api('/restaurants/verify-email')).send({ token: newToken, password: `Pw-${uniq('b')}-1` }).expect(201);
    // once activated it leaves the queue and cannot be resent
    const q = (await t.http().get(api('/restaurants/registrations?state=all')).set(auth(sa)).expect(200)).body;
    expect(q.items.map((i: { id: string }) => i.id)).not.toContain(r.registrationId);
    expect((await t.http().post(api(`/restaurants/registrations/${r.registrationId}/resend`)).set(auth(sa)).expect(409)).body.code).toBe('already_verified');
  });

  it('cancel needs a reason, kills the link, frees the email for a new registration; auditors cannot act', async () => {
    const r = await register(uniq('Cancel Bistro'));
    const token = t.mailer.lastTokenFor(r.ownerEmail);
    await t.http().post(api(`/restaurants/registrations/${r.registrationId}/cancel`)).set(auth(auditor)).send({ reason: 'typo in name' }).expect(403);
    await t.http().post(api(`/restaurants/registrations/${r.registrationId}/cancel`)).set(auth(sa)).send({}).expect(400);
    await t.http().post(api(`/restaurants/registrations/${r.registrationId}/cancel`)).set(auth(sa)).send({ reason: 'typo in name' }).expect(200);
    await t.http().post(api('/restaurants/verify-email')).send({ token, password: `Pw-${uniq('c')}-1` }).expect(400);
    const cancelled = (await t.http().get(api('/restaurants/registrations?state=cancelled')).set(auth(sa)).expect(200)).body;
    expect(cancelled.items.find((i: { id: string }) => i.id === r.registrationId)).toMatchObject({ state: 'cancelled', cancelReason: 'typo in name' });
    // the same email can be registered again right away
    await t.http().post(api('/restaurants')).set(auth(sa)).send({ ownerEmail: r.ownerEmail, ownerName: 'Owner', restaurantName: 'Fixed Name', planCode: 'standard' }).expect(201);
  });

  it('a failed send is recorded on the registration so the queue shows it', async () => {
    t.mailer.failNext = true;
    const r = await register(uniq('Bounce Inn'));
    expect(r.emailSent).toBe(false);
    const q = (await t.http().get(api('/restaurants/registrations?state=all')).set(auth(sa)).expect(200)).body;
    expect(q.items.find((i: { id: string }) => i.id === r.registrationId).lastEmailError).toContain('own email');
  });
});
