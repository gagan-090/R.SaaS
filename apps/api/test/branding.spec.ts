/** Restaurant branding: a plan feature the Super Admin controls; owners set colour, logo and text style; hubs receive it. */
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

const PNG = Buffer.concat([
  Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63fcffff3f0300050001ff5a4a6b1f0000000049454e44ae426082', 'hex'),
  Buffer.alloc(32, 0),
]).toString('base64');
const STYLE = { color: '#1a73e8', textSize: 'large', headingWeight: 'heavy', headingCase: 'upper' };

describe('branding', () => {
  let t: TestApp;
  let saToken: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    const sa = await createAdmin(t, ['Super Admin']);
    saToken = (await loginAdmin(t, sa)).accessToken;
  });
  afterAll(() => t.close());

  it('a plan without branding: the owner sees it is off and cannot save', async () => {
    const std = await onboardRestaurant(t, saToken, 'standard');
    const g = (await t.http().get(api('/tenant/branding')).set(bearer(std.ownerToken)).expect(200)).body;
    expect(g).toMatchObject({ enabled: false, branding: null });
    const r = await t.http().put(api('/tenant/branding')).set(bearer(std.ownerToken)).send(STYLE).expect(403);
    expect(r.body.code).toBe('feature_not_in_plan');
    await t.http().put(api('/tenant/branding/logo')).set(bearer(std.ownerToken)).send({ contentType: 'image/png', dataBase64: PNG }).expect(403);
  });

  it('premium owner sets colour, text style and logo; the overview and the hub pull carry it; bad input is refused', async () => {
    const prem = await onboardRestaurant(t, saToken, 'premium');
    const auth = bearer(prem.ownerToken);
    await t.http().put(api('/tenant/branding')).set(auth).send({ ...STYLE, color: 'blue' }).expect(400);
    await t.http().put(api('/tenant/branding')).set(auth).send({ ...STYLE, textSize: 'huge' }).expect(400);
    const saved = (await t.http().put(api('/tenant/branding')).set(auth).send(STYLE).expect(200)).body;
    expect(saved).toMatchObject({ ...STYLE, color: '#1A73E8', logoImageId: null });

    const logo = (await t.http().put(api('/tenant/branding/logo')).set(auth).send({ contentType: 'image/png', dataBase64: PNG }).expect(200)).body;
    expect(logo.logoImageId).toBeTruthy();
    await t.http().get(api(`/media/${logo.logoImageId}`)).expect(200);

    const o = (await t.http().get(api('/tenant/overview')).set(auth).expect(200)).body;
    expect(o.branding).toMatchObject({ color: '#1A73E8', textSize: 'large', logoImageId: logo.logoImageId });

    const reg = (await t.http().post(api('/devices/register-hub')).set(auth).send({ name: 'Hub', platform: 'android' }).expect(201)).body;
    const pull = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', reg.deviceToken).expect(200)).body;
    expect(pull.tenant.branding).toMatchObject({ color: '#1A73E8', headingCase: 'upper', logoImageId: logo.logoImageId });

    await t.http().delete(api('/tenant/branding/logo')).set(auth).expect(204);
    expect((await t.owner.media.findUnique({ where: { id: logo.logoImageId } }))).toBeNull();
    const audit = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'tenant.branding_updated', tenantId: prem.tenantId } });
    expect(audit.after).toMatchObject({ color: '#1A73E8' });
  });

  it('the Super Admin switches branding on for a plan: restaurants already on it get it at once', async () => {
    const code = `brand_${Date.now().toString(36)}`;
    const plan = (await t.http().post(api('/plans')).set(bearer(saToken))
      .send({ code, name: 'Basic', featureFlags: ['tables', 'menu', 'billing'], limits: { branches: 1 }, pricePaise: 0 }).expect(201)).body;
    const r = await onboardRestaurant(t, saToken, code);
    await t.http().put(api('/tenant/branding')).set(bearer(r.ownerToken)).send(STYLE).expect(403);

    const upd = (await t.http().patch(api(`/plans/${plan.id}`)).set(bearer(saToken)).send({ featureFlags: ['tables', 'menu', 'billing', 'branding'] }).expect(200)).body;
    expect(upd.licensesUpdated).toBe(1);
    expect((await t.http().get(api('/tenant/branding')).set(bearer(r.ownerToken)).expect(200)).body.enabled).toBe(true);
    await t.http().put(api('/tenant/branding')).set(bearer(r.ownerToken)).send(STYLE).expect(200);

    // switched off again: the saved look is kept but no longer applied anywhere
    await t.http().patch(api(`/plans/${plan.id}`)).set(bearer(saToken)).send({ featureFlags: ['tables', 'menu', 'billing'] }).expect(200);
    const off = (await t.http().get(api('/tenant/branding')).set(bearer(r.ownerToken)).expect(200)).body;
    expect(off).toMatchObject({ enabled: false, branding: null, saved: expect.objectContaining({ color: '#1A73E8' }) });
    expect((await t.http().get(api('/tenant/overview')).set(bearer(r.ownerToken)).expect(200)).body.branding).toBeNull();
  });
});
