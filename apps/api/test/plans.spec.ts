/** Plans: the Super Admin sets prices, adds plans, sells custom plans and archives old ones (never deleted). */
import { randomInt } from 'crypto';
import { pinProblem } from '../src/staff/pin-policy';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant, uniq } from './helpers';

describe('plans', () => {
  let t: TestApp;
  let sa: string;
  let onboarding: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    onboarding = (await loginAdmin(t, await createAdmin(t, ['Onboarding Admin']))).accessToken;
  });
  afterAll(() => t.close());

  it('Super Admin adds a priced plan, reprices it, sells it, then archives it; archived plans cannot be sold', async () => {
    const code = uniq('pro_plus').replace(/-/g, '_').toLowerCase().slice(0, 30);
    const created = (await t.http().post(api('/plans')).set(bearer(sa)).send({
      code, name: 'Pro Plus', featureFlags: ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single', 'lan_hub'],
      limits: { branches: 1, devicesPerBranch: 3 }, pricePaise: 149900, billingCycle: 'monthly',
    }).expect(201)).body;
    expect(created).toMatchObject({ code, pricePaise: 149900, archived: false });

    const repriced = (await t.http().patch(api(`/plans/${created.id}`)).set(bearer(sa)).send({ pricePaise: 199900, billingCycle: 'yearly' }).expect(200)).body;
    expect(repriced).toMatchObject({ pricePaise: 199900, billingCycle: 'yearly' });
    expect(await t.owner.auditEvent.count({ where: { action: 'plan.updated', objectId: created.id } })).toBe(1);

    // a custom plan can be sold (not only the three built-ins)
    await t.http().post(api('/restaurants')).set(bearer(sa))
      .send({ ownerEmail: `${uniq('o')}@example.test`, ownerName: 'O', restaurantName: uniq('R'), planCode: code }).expect(201);

    const listed = (await t.http().get(api('/plans')).set(bearer(onboarding)).expect(200)).body as { code: string; activeLicenses: number }[];
    expect(listed.find((p) => p.code === code)).toMatchObject({ activeLicenses: 0 });

    await t.http().patch(api(`/plans/${created.id}`)).set(bearer(sa)).send({ archived: true }).expect(200);
    expect(((await t.http().get(api('/plans')).set(bearer(sa)).expect(200)).body as { code: string }[]).map((p) => p.code)).not.toContain(code);
    expect(((await t.http().get(api('/plans?includeArchived=true')).set(bearer(sa)).expect(200)).body as { code: string }[]).map((p) => p.code)).toContain(code);
    const r = await t.http().post(api('/restaurants')).set(bearer(sa))
      .send({ ownerEmail: `${uniq('o')}@example.test`, ownerName: 'O', restaurantName: uniq('R'), planCode: code }).expect(400);
    expect(r.body.code).toBe('unknown_plan');
  });

  it('only plan managers change plans; bad flags and duplicate codes are refused', async () => {
    const list = (await t.http().get(api('/plans')).set(bearer(sa)).expect(200)).body as { id: string; code: string }[];
    const standard = list.find((p) => p.code === 'standard')!;
    await t.http().patch(api(`/plans/${standard.id}`)).set(bearer(onboarding)).send({ pricePaise: 1 }).expect(403);
    await t.http().post(api('/plans')).set(bearer(sa)).send({ code: 'standard', name: 'x', featureFlags: [], limits: {}, pricePaise: 0 }).expect(409);
    await t.http().post(api('/plans')).set(bearer(sa)).send({ code: 'weird_one', name: 'x', featureFlags: ['teleport'], limits: {}, pricePaise: 0 }).expect(400);
    await t.http().patch(api(`/plans/${standard.id}`)).set(bearer(sa)).send({ pricePaise: -5 }).expect(400);
  });

  it('enabling portal, floor editor and Excel updates existing licenses; disabling retains data and blocks writes', async () => {
    const flags = ['tables', 'menu', 'billing', 'inventory'];
    const code = uniq('portal').replace(/-/g, '_').slice(0, 30);
    const plan = (await t.http().post(api('/plans')).set(bearer(sa)).send({
      code, name: 'Existing restaurant plan', featureFlags: flags, limits: { branches: 1 }, pricePaise: 12300,
    }).expect(201)).body;
    const r = await onboardRestaurant(t, sa, code);
    const auth = bearer(r.ownerToken);
    const floor = (await t.http().post(api('/floors')).set(auth).send({ branchId: r.branchId, name: 'Ground' }).expect(201)).body;
    const layout = { version: 1, width: 1200, height: 800, tables: [
      { name: '1', seats: 4, shape: 'square', x: 320, y: 240, width: 80, height: 80, rotation: 0 },
    ] };
    let pin: string;
    do { pin = String(randomInt(100000, 99999999)); } while (pinProblem(pin));
    const email = `${uniq('employee')}@example.test`;
    const staff = (await t.http().post(api('/staff')).set(auth).send({ name: 'Waiter', email, pin, role: 'waiter' }).expect(201)).body;
    await t.http().patch(api(`/staff/${staff.id}`)).set(auth).send({ webAccess: true }).expect(403);
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth).send(layout).expect(403);
    for (const kind of ['menu', 'inventory']) {
      await t.http().get(api(`/imports/templates/${kind}`)).set(auth).expect(403);
    }

    const updated = (await t.http().patch(api(`/plans/${plan.id}`)).set(bearer(sa)).send({
      featureFlags: [...flags, 'staff_portal', 'floor.editor', 'import.excel'],
    }).expect(200)).body;
    expect(updated).toMatchObject({ licensesUpdated: 1, pricePaise: 12300, limits: { branches: 1 } });
    expect((await t.http().get(api('/me')).set(auth).expect(200)).body.permissions).toContain('import.run');
    await t.http().patch(api(`/staff/${staff.id}`)).set(auth).send({ webAccess: true }).expect(200);
    await t.http().post(api('/auth/pin-login')).send({ email, pin }).expect(200);
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth).send(layout).expect(200);
    const saved = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth).expect(200)).body;
    expect(saved.tables[0]).toMatchObject({ x: 320, y: 240 });
    for (const kind of ['menu', 'inventory']) {
      const template = await t.http().get(api(`/imports/templates/${kind}`)).set(auth).expect(200);
      expect(template.headers['content-type']).toContain('spreadsheetml');
    }

    await t.http().patch(api(`/plans/${plan.id}`)).set(bearer(sa)).send({ featureFlags: flags }).expect(200);
    await t.http().post(api('/auth/pin-login')).send({ email, pin }).expect(403);
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth).send({ ...layout, version: 2 }).expect(403);
    await t.http().get(api('/imports/templates/menu')).set(auth).expect(403);
    expect((await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth).expect(200)).body.tables[0]).toMatchObject({ x: 320, y: 240 });
  });
});

describe('verification email', () => {
  let t: TestApp;
  let sa: string;
  beforeAll(async () => {
    t = await createTestApp();
    sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
  });
  afterAll(() => t.close());

  it('links to the console set-password page, with HTML and text; a failed send still hands the link to the Super Admin', async () => {
    const ownerEmail = `${uniq('o')}@example.test`;
    const r = (await t.http().post(api('/restaurants')).set('Authorization', `Bearer ${sa}`)
      .send({ ownerEmail, ownerName: 'Meera', restaurantName: 'Spice Route', planCode: 'standard' }).expect(201)).body;
    expect(r).toMatchObject({ emailSent: true, status: 'pending_verification' });
    expect(r.verifyUrl).toBeUndefined(); // the token only travels by email when the email works
    const m = t.mailer.sent.at(-1)!;
    expect(m.to).toBe(ownerEmail);
    expect(m.subject).toBe('Activate Spice Route on House Plating');
    expect(m.text).toMatch(/\/#\/verify-email\?token=[A-Za-z0-9_-]+/);
    expect(m.html).toContain('Confirm email &amp; set password');
    expect(m.html).toContain('Meera');

    t.mailer.failNext = true;
    const failed = (await t.http().post(api('/restaurants')).set('Authorization', `Bearer ${sa}`)
      .send({ ownerEmail: `${uniq('o')}@example.test`, ownerName: 'X', restaurantName: 'Y', planCode: 'standard' }).expect(201)).body;
    expect(failed.emailSent).toBe(false);
    expect(failed.emailError).toContain('own email');
    expect(failed.verifyUrl).toMatch(/\/#\/verify-email\?token=/);
    // the link works: the owner sets a password and the restaurant is created
    const token = new URL(failed.verifyUrl.replace('/#/', '/')).searchParams.get('token');
    await t.http().post(api('/restaurants/verify-email')).send({ token, password: `Pw-${uniq('v')}-9` }).expect(201);
  });
});
