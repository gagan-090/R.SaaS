/** Standard plan: one device run by the owner (no employees), with the visual floor editor; licenses follow the plan. */
import { LicenseService } from '../src/licensing/license.service';
import { STANDARD_CATEGORIES } from '../src/menu/menu.controller';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant, uniq } from './helpers';

describe('Standard plan', () => {
  let t: TestApp;
  let sa: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
  });
  afterAll(() => t.close());

  it('the migration gives Standard the floor editor and no employees (owner only)', async () => {
    const plan = await t.owner.subscriptionPlan.findUniqueOrThrow({ where: { code: 'standard' } });
    expect(plan.featureFlags).toContain('floor.editor');
    expect(plan.featureFlags).not.toContain('waiter_app');
    expect(plan.featureFlags).not.toContain('lan_hub');
    expect(plan.limits).toMatchObject({ staffPerBranch: 0, devicesPerBranch: 1 });
  });

  it('a Standard owner cannot add a cashier or a waiter; the console is told it is owner only', async () => {
    const std = await onboardRestaurant(t, sa, 'standard');
    for (const role of ['cashier', 'waiter']) {
      const r = await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: role, email: `${uniq(role)}@example.test`, role, pin: '482915' }).expect(403);
      expect(r.body.code).toBe('employee_limit');
    }
    // the console reads the plan from /me to leave Staff out of the menu
    const me = (await t.http().get(api('/me')).set(bearer(std.ownerToken)).expect(200)).body;
    expect(me.plan).toMatchObject({ state: 'active', limits: { staffPerBranch: 0 } });
    expect(me.plan.features).toContain('floor.editor');
    const limits = (await t.http().get(api('/staff/limits')).set(bearer(std.ownerToken)).expect(200)).body;
    expect(limits).toMatchObject({ employeeLimit: 0, activeEmployees: 0 });
    // Professional still adds people
    const pro = await onboardRestaurant(t, sa, 'professional');
    await t.http().post(api('/staff')).set(bearer(pro.ownerToken)).send({ name: 'Ravi', email: `${uniq('w')}@example.test`, role: 'waiter', pin: '482915' }).expect(201);
  });

  it('a license signed before the plan changed is re-signed to match it (same dates)', async () => {
    const std = await onboardRestaurant(t, sa, 'standard');
    const licenses = t.app.get(LicenseService);
    const lic = await t.owner.license.findFirstOrThrow({ where: { tenantId: std.tenantId, status: 'active' }, include: { plan: true } });
    // the token as it was signed under the old Standard (no floor editor, employees unlimited)
    const old = { ...lic.plan, featureFlags: lic.plan.featureFlags.filter((f) => f !== 'floor.editor'), limits: { ...(lic.plan.limits as object), staffPerBranch: null } };
    await t.owner.license.update({ where: { id: lic.id }, data: { signedToken: licenses.buildToken(lic, old) } });
    const before = await t.owner.$transaction((tx) => licenses.entitlement(tx, std.tenantId));
    expect(before.features).not.toContain('floor.editor');

    expect(await t.owner.$transaction((tx) => licenses.resyncWithPlans(tx))).toBeGreaterThanOrEqual(1);
    const after = await t.owner.$transaction((tx) => licenses.entitlement(tx, std.tenantId));
    expect(after.features).toContain('floor.editor');
    expect(after.limits).toMatchObject({ staffPerBranch: 0 });
    const again = await t.owner.license.findUniqueOrThrow({ where: { id: lic.id } });
    expect([again.startsAt, again.endsAt]).toEqual([lic.startsAt, lic.endsAt]);
    // nothing left to change: a second run touches nothing for this restaurant
    await t.owner.$transaction((tx) => licenses.resyncWithPlans(tx));
    expect((await t.owner.license.findUniqueOrThrow({ where: { id: lic.id } })).signedToken).toBe(again.signedToken);
  });

  it('a new restaurant starts with the 9 main categories and one floor; the owner can rename and delete them', async () => {
    const std = await onboardRestaurant(t, sa, 'standard');
    const auth = bearer(std.ownerToken);
    const cats = (await t.http().get(api('/menu/categories')).set(auth).expect(200)).body as { id: string; name: string }[];
    expect(cats.map((c) => c.name)).toEqual(STANDARD_CATEGORIES);
    const floors = (await t.http().get(api('/floors')).set(auth).expect(200)).body as { name: string; branchId: string }[];
    expect(floors.map((f) => [f.name, f.branchId])).toEqual([['Ground floor', std.branchId]]);
    // they are ordinary categories: rename one, delete another
    const soups = cats.find((c) => c.name === 'Soups')!;
    await t.http().patch(api(`/menu/categories/${soups.id}`)).set(auth).send({ name: 'Soups & Shorba' }).expect(200);
    const chinese = cats.find((c) => c.name === 'Chinese')!;
    await t.http().delete(api(`/menu/categories/${chinese.id}`)).set(auth).expect(204);
    const after = ((await t.http().get(api('/menu/categories')).set(auth).expect(200)).body as { name: string }[]).map((c) => c.name);
    expect(after).toContain('Soups & Shorba');
    expect(after).not.toContain('Chinese');
    // "Add standard categories" brings back only what is missing
    const seeded = (await t.http().post(api('/menu/seed-categories')).set(auth).expect(201)).body;
    expect(seeded.created).toBe(2); // Soups (renamed away) and Chinese (deleted)
  });

  it('"Add standard categories" adds the 9 main categories, once', async () => {
    const std = await onboardRestaurant(t, sa, 'standard');
    for (const c of (await t.http().get(api('/menu/categories')).set(bearer(std.ownerToken)).expect(200)).body as { id: string }[]) {
      await t.owner.menuCategory.delete({ where: { id: c.id } }); // a restaurant from before the defaults
    }
    const first = (await t.http().post(api('/menu/seed-categories')).set(bearer(std.ownerToken)).expect(201)).body;
    expect(first).toMatchObject({ created: 9, total: 9 });
    const names = (await t.http().get(api('/menu/categories')).set(bearer(std.ownerToken)).expect(200)).body.map((c: { name: string }) => c.name);
    expect(names).toEqual(STANDARD_CATEGORIES);
    expect(STANDARD_CATEGORIES).toEqual(['Beverages', 'Soups', 'Starters', 'Snacks & Fast Food', 'Main Course', 'Chinese', 'Indian Breads', 'Rice & Biryani', 'Desserts']);
    expect((await t.http().post(api('/menu/seed-categories')).set(bearer(std.ownerToken)).expect(201)).body).toMatchObject({ created: 0 });
  });
});
