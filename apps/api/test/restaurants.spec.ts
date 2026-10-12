/**
 * M3 — restaurant lifecycle & licensing. AC-01 (onboarding) and AC-02 (license enforcement).
 */
import { loadEnv } from '../src/config/env';
import { licenseState, signLicense, verifyLicense } from '../src/licensing/license-token';
import { uuidv7 } from '../src/common/uuid';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant, uniq } from './helpers';

const DAY = 86400_000;

describe('restaurants & licensing', () => {
  let t: TestApp;
  let sa: string; // super admin access token
  let saId: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    const a = await createAdmin(t, ['Super Admin']);
    saId = a.id;
    sa = (await loginAdmin(t, a)).accessToken;
  });
  afterAll(() => t.close());

  /** Replaces the tenant's active license with one whose signed window is [start, end] (days relative to now). */
  async function setLicenseWindow(tenantId: string, startDays: number, endDays: number, planCode = 'standard') {
    const plan = await t.owner.subscriptionPlan.findUniqueOrThrow({ where: { code: planCode } });
    const id = uuidv7();
    const startsAt = new Date(Date.now() + startDays * DAY);
    const endsAt = new Date(Date.now() + endDays * DAY);
    const token = signLicense(
      { v: 1, lic: id, tid: tenantId, plan: plan.code, features: plan.featureFlags, limits: plan.limits as Record<string, number | null>, nbf: Math.floor(+startsAt / 1000), exp: Math.floor(+endsAt / 1000), grace_days: 7, iat: Math.floor(Date.now() / 1000) },
      loadEnv().LICENSE_SIGNING_PRIVATE_KEY,
    );
    await t.owner.license.updateMany({ where: { tenantId, status: 'active' }, data: { status: 'superseded' } });
    await t.owner.license.create({ data: { id, tenantId, planId: plan.id, startsAt, endsAt, signedToken: token, issuedBy: saId, reason: 'test' } });
  }

  describe('AC-01 tenant onboarding', () => {
    it('verified email creates an isolated tenant with a plan-bound license; nothing exists before verification', async () => {
      const ownerEmail = `${uniq('own')}@example.test`;
      const reg = await t.http().post(api('/restaurants')).set(bearer(sa))
        .send({ ownerEmail, ownerName: 'Asha', restaurantName: 'Spice Route', gstin: '27AAAPA1234A1Z5', planCode: 'professional' }).expect(201);
      expect(reg.body.status).toBe('pending_verification');
      expect(JSON.stringify(reg.body)).not.toMatch(/token/i); // the link only goes to the owner's inbox
      expect(await t.owner.restaurantTenant.count({ where: { ownerEmail } })).toBe(0);

      const token = t.mailer.lastTokenFor(ownerEmail);
      const v = await t.http().post(api('/restaurants/verify-email')).send({ token, password: 'Owner-' + uniq() }).expect(201);
      expect(v.body.code).toMatch(/^R\d{6}$/);
      expect(v.body.license.planCode).toBe('professional');

      const tenant = await t.owner.restaurantTenant.findUniqueOrThrow({ where: { id: v.body.tenantId } });
      expect(tenant).toMatchObject({ status: 'active', ownerEmail, name: 'Spice Route' });
      const lic = await t.owner.license.findFirstOrThrow({ where: { tenantId: tenant.id, status: 'active' } });
      const payload = verifyLicense(lic.signedToken, loadEnv().LICENSE_PUBLIC_KEY);
      expect(payload).toMatchObject({ tid: tenant.id, plan: 'professional', grace_days: 7 });
      expect(payload!.features).toContain('lan_hub');
      expect(await t.owner.branch.count({ where: { tenantId: tenant.id } })).toBe(1);
      expect(await t.owner.userRoleAssignment.count({ where: { tenantId: tenant.id, role: 'owner' } })).toBe(1);
      expect(await t.owner.auditEvent.count({ where: { tenantId: tenant.id, action: 'restaurant.created' } })).toBe(1);

      // the link works once
      await t.http().post(api('/restaurants/verify-email')).send({ token, password: 'Owner-' + uniq() }).expect(409);
      await t.http().post(api('/restaurants/verify-email')).send({ token: 'garbage', password: 'Owner-' + uniq() }).expect(400);
    });

    it('duplicate owner email is rejected (pending and verified)', async () => {
      const ownerEmail = `${uniq('dup')}@example.test`;
      const body = { ownerEmail, ownerName: 'X', restaurantName: 'Y', planCode: 'standard' };
      await t.http().post(api('/restaurants')).set(bearer(sa)).send(body).expect(201);
      const pending = await t.http().post(api('/restaurants')).set(bearer(sa)).send(body).expect(409);
      expect(pending.body.code).toBe('duplicate_email');
      await t.http().post(api('/restaurants/verify-email')).send({ token: t.mailer.lastTokenFor(ownerEmail), password: 'Owner-' + uniq() }).expect(201);
      const verified = await t.http().post(api('/restaurants')).set(bearer(sa)).send({ ...body, ownerEmail: ownerEmail.toUpperCase() }).expect(409);
      expect(verified.body.code).toBe('duplicate_email');
    });

    it('validates input: bad GSTIN and unknown plan are 400', async () => {
      await t.http().post(api('/restaurants')).set(bearer(sa)).send({ ownerEmail: `${uniq()}@e.test`, ownerName: 'X', restaurantName: 'Y', planCode: 'gold' }).expect(400);
      await t.http().post(api('/restaurants')).set(bearer(sa)).send({ ownerEmail: `${uniq()}@e.test`, ownerName: 'X', restaurantName: 'Y', planCode: 'standard', gstin: 'NOTAGSTIN' }).expect(400);
    });
  });

  describe('list / search / filter / status', () => {
    it('filters by status, plan and search text', async () => {
      const R = await onboardRestaurant(t, sa, 'premium');
      const byPlan = await t.http().get(api('/restaurants?plan=premium&pageSize=200')).set(bearer(sa)).expect(200);
      expect(byPlan.body.items.some((r: { id: string }) => r.id === R.tenantId)).toBe(true);
      expect(byPlan.body.items.every((r: { plan: string }) => r.plan === 'premium')).toBe(true);
      const byCode = await t.http().get(api(`/restaurants?q=${R.code}`)).set(bearer(sa)).expect(200);
      expect(byCode.body.items.map((r: { id: string }) => r.id)).toEqual([R.tenantId]);
      const byOwner = await t.http().get(api(`/restaurants?owner=${encodeURIComponent(R.ownerEmail)}`)).set(bearer(sa)).expect(200);
      expect(byOwner.body.total).toBe(1);
      const detail = await t.http().get(api(`/restaurants/${R.tenantId}`)).set(bearer(sa)).expect(200);
      expect(detail.body.entitlement.state).toBe('active');
    });

    it('enforces status transitions and requires a reason', async () => {
      const R = await onboardRestaurant(t, sa);
      const s = (action: string, reason?: string) => t.http().post(api(`/restaurants/${R.tenantId}/status`)).set(bearer(sa)).send({ action, reason });
      await s('suspend').expect(400);
      await s('activate', 'already active').expect(409);
      await s('suspend', 'unpaid').expect(200);
      await s('suspend', 'again').expect(409);
      await s('block', 'fraud check').expect(200);
      await s('reactivate', 'cleared').expect(200);
      const list = await t.http().get(api(`/restaurants?q=${R.code}&status=active`)).set(bearer(sa)).expect(200);
      expect(list.body.total).toBe(1);
      expect(await t.owner.auditEvent.count({ where: { tenantId: R.tenantId, action: 'restaurant.status_changed' } })).toBe(3);
    });
  });

  describe('AC-02 license enforcement', () => {
    it('tampered license token fails signature verification', async () => {
      const R = await onboardRestaurant(t, sa);
      const lic = await t.owner.license.findFirstOrThrow({ where: { tenantId: R.tenantId, status: 'active' } });
      expect(verifyLicense(lic.signedToken, loadEnv().LICENSE_PUBLIC_KEY)).not.toBeNull();
      const [body, sig] = lic.signedToken.split('.');
      const p = JSON.parse(Buffer.from(body, 'base64url').toString());
      p.plan = 'premium';
      p.features.push('franchise', 'kds');
      const forged = `${Buffer.from(JSON.stringify(p)).toString('base64url')}.${sig}`;
      expect(verifyLicense(forged, loadEnv().LICENSE_PUBLIC_KEY)).toBeNull();
      // and if someone writes the forged token into the DB, the API refuses the tenant rather than trusting it
      await t.owner.license.update({ where: { id: lic.id }, data: { signedToken: forged } });
      const r = await t.http().get(api('/branches')).set(bearer(R.ownerToken)).expect(403);
      expect(r.body.code).toBe('feature_not_in_plan');
      await t.http().post(api('/tax-rules')).set(bearer(R.ownerToken)).send({ name: 'GST 5%', rateBp: 500 }).expect(403);
    });

    it('a plan without the feature gets 403; upgrading unlocks it', async () => {
      const R = await onboardRestaurant(t, sa, 'standard');
      const r = await t.http().get(api('/branches')).set(bearer(R.ownerToken)).expect(403);
      expect(r.body.code).toBe('feature_not_in_plan');
      await t.http().post(api(`/restaurants/${R.tenantId}/licenses`)).set(bearer(sa)).send({ action: 'downgrade', planCode: 'premium', reason: 'wrong way' }).expect(400);
      await t.http().post(api(`/restaurants/${R.tenantId}/licenses`)).set(bearer(sa)).send({ action: 'upgrade', planCode: 'premium', reason: 'customer upgraded' }).expect(201);
      await t.http().get(api('/branches')).set(bearer(R.ownerToken)).expect(200);
      const ev = await t.owner.auditEvent.findFirstOrThrow({ where: { tenantId: R.tenantId, action: 'license.upgrade' } });
      expect(ev.reason).toBe('customer upgraded');
    });

    it('expired license: full access during 7-day grace, then read-only (reads ok, writes 403)', async () => {
      const R = await onboardRestaurant(t, sa);
      const write = () => t.http().post(api('/tax-rules')).set(bearer(R.ownerToken)).send({ name: 'GST 5%', rateBp: 500 });
      await setLicenseWindow(R.tenantId, -40, -3); // ended 3 days ago → grace
      expect((await t.http().get(api('/tenant/license')).set(bearer(R.ownerToken)).expect(200)).body.state).toBe('grace');
      await write().expect(201);
      await setLicenseWindow(R.tenantId, -40, -8); // ended 8 days ago → read-only
      const w = await write().expect(403);
      expect(w.body.code).toBe('license_read_only');
      await t.http().get(api('/tax-rules')).set(bearer(R.ownerToken)).expect(200);
      // renew restores writes
      await t.http().post(api(`/restaurants/${R.tenantId}/licenses`)).set(bearer(sa)).send({ action: 'renew', reason: 'paid' }).expect(201);
      await write().expect(201);
    });

    it('blocked or suspended tenant is read-only immediately; revoked license too', async () => {
      const R = await onboardRestaurant(t, sa);
      const write = () => t.http().post(api('/tax-rules')).set(bearer(R.ownerToken)).send({ name: 'GST 0%', rateBp: 0 });
      await t.http().post(api(`/restaurants/${R.tenantId}/status`)).set(bearer(sa)).send({ action: 'block', reason: 'chargeback' }).expect(200);
      expect((await write().expect(403)).body.code).toBe('license_read_only');
      await t.http().get(api('/tax-rules')).set(bearer(R.ownerToken)).expect(200); // history stays visible
      await t.http().post(api(`/restaurants/${R.tenantId}/status`)).set(bearer(sa)).send({ action: 'reactivate', reason: 'resolved' }).expect(200);
      await write().expect(201);
      await t.http().post(api(`/restaurants/${R.tenantId}/licenses`)).set(bearer(sa)).send({ action: 'revoke', reason: 'contract ended' }).expect(201);
      await write().expect(403);
    });

    it('licenseState follows nbf / exp / grace', () => {
      const now = new Date('2026-10-12T00:00:00Z');
      const s = (nbfD: number, expD: number) => licenseState({ nbf: +now / 1000 + nbfD * 86400, exp: +now / 1000 + expD * 86400, grace_days: 7 }, now);
      expect(s(1, 30)).toBe('not_started');
      expect(s(-1, 30)).toBe('active');
      expect(s(-30, -6.9)).toBe('grace');
      expect(s(-30, -7)).toBe('read_only');
    });

    it('current token endpoint returns a verifiable token and the public key', async () => {
      const R = await onboardRestaurant(t, sa);
      const r = await t.http().get(api(`/restaurants/${R.tenantId}/licenses/current/token`)).set(bearer(sa)).expect(200);
      expect(verifyLicense(r.body.token, r.body.publicKey)?.tid).toBe(R.tenantId);
    });

    it('records subscription payments', async () => {
      const R = await onboardRestaurant(t, sa);
      await t.http().post(api(`/restaurants/${R.tenantId}/payments`)).set(bearer(sa)).send({ amountPaise: 99900, method: 'upi', paidAt: new Date().toISOString(), reference: 'UTR123' }).expect(201);
      await t.http().post(api(`/restaurants/${R.tenantId}/payments`)).set(bearer(sa)).send({ amountPaise: 1.5, method: 'upi', paidAt: new Date().toISOString() }).expect(400);
    });
  });
});
