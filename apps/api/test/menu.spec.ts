/** Menu categories, items and their sizes / portions (variants), as the owner builds them and the hub receives them. */
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

describe('menu with sizes and portions', () => {
  let t: TestApp;
  let r: Awaited<ReturnType<typeof onboardRestaurant>>;
  let other: Awaited<ReturnType<typeof onboardRestaurant>>;
  let tax: { id: string };
  let drinks: { id: string };
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const auth = () => bearer(r.ownerToken);

  beforeAll(async () => {
    t = await createTestApp();
    const sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    r = await onboardRestaurant(t, sa, 'premium');
    other = await onboardRestaurant(t, sa, 'premium');
    tax = (await t.http().post(api('/tax-rules')).set(auth()).send({ name: 'GST 5%', rateBp: 500 }).expect(201)).body;
    drinks = (await t.http().post(api('/menu/categories')).set(auth()).send({ name: 'Soft Drinks' }).expect(201)).body;
  });
  afterAll(() => t.close());

  it('Menu → Category → Item → sizes with their own quantities and prices → saved with stable codes', async () => {
    const cola = (await t.http().post(api('/menu/items')).set(auth()).send({
      categoryId: drinks.id, name: 'Cola', taxRuleId: tax.id,
      variants: [
        { name: '250 ml', servingQuantity: 250, servingUnit: 'ml', portionRatio: 0.25, pricePaise: 3000 },
        { name: '500 ml', servingQuantity: 500, servingUnit: 'ml', portionRatio: 0.5, pricePaise: 5000, isDefault: true },
        { name: '1 litre', servingQuantity: 1, servingUnit: 'l', pricePaise: 9000 },
      ],
    }).expect(201)).body;
    expect(cola.code).toMatch(/^ITEM-\d{4}$/);
    expect(cola.variants.map((v: { name: string; pricePaise: number; servingQuantity: number; servingUnit: string }) => [v.name, v.pricePaise, v.servingQuantity, v.servingUnit]))
      .toEqual([['250 ml', 3000, 250, 'ml'], ['500 ml', 5000, 500, 'ml'], ['1 litre', 9000, 1, 'l']]);
    expect(cola.variants.find((v: { isDefault: boolean }) => v.isDefault).name).toBe('500 ml');
    expect(cola.pricePaise).toBe(5000); // legacy price follows the default size
    expect(new Set(cola.variants.map((v: { code: string }) => v.code)).size).toBe(3);

    // a quarter is not assumed to cost a quarter: each price is explicit
    const mains = (await t.http().post(api('/menu/categories')).set(auth()).send({ name: 'Main Course' }).expect(201)).body;
    const biryani = (await t.http().post(api('/menu/items')).set(auth()).send({
      categoryId: mains.id, code: 'BIRYANI', name: 'Biryani', taxRuleId: tax.id,
      variants: [
        { code: 'BIR-Q', name: 'Quarter plate', portionLabel: 'quarter', servingQuantity: 1, servingUnit: 'plate', portionRatio: 0.3, pricePaise: 12000 },
        { code: 'BIR-H', name: 'Half plate', portionLabel: 'half', servingQuantity: 1, servingUnit: 'plate', portionRatio: 0.55, pricePaise: 22000 },
        { code: 'BIR-F', name: 'Full plate', portionLabel: 'full', servingQuantity: 1, servingUnit: 'plate', portionRatio: 1, pricePaise: 40000, isDefault: true },
      ],
    }).expect(201)).body;
    expect(biryani.variants.map((v: { code: string; portionRatio: number }) => [v.code, v.portionRatio])).toEqual([['BIR-Q', 0.3], ['BIR-H', 0.55], ['BIR-F', 1]]);
  });

  it('validates: units, quantity with unit, one default, duplicate codes in the item, the restaurant, or retired', async () => {
    const base = { categoryId: drinks.id, name: 'Water', taxRuleId: tax.id };
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [{ name: 'x', servingQuantity: 500, servingUnit: 'gallon', pricePaise: 100 }] }).expect(400);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [{ name: 'x', servingQuantity: 500, pricePaise: 100 }] }).expect(400);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [{ name: 'a', pricePaise: 1, isDefault: true }, { name: 'b', pricePaise: 2, isDefault: true }] }).expect(400);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [{ code: 'W1', name: 'a', pricePaise: 1 }, { code: 'w1', name: 'b', pricePaise: 2 }] }).expect(409);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [{ code: 'BIR-H', name: 'a', pricePaise: 1 }] }).expect(409);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [] }).expect(400);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, code: 'BIRYANI', pricePaise: 100 }).expect(409);
    await t.http().post(api('/menu/items')).set(auth()).send({ ...base, variants: [{ name: 'neg', pricePaise: -5 }] }).expect(400);
  });

  it('older clients that send one price get a "Regular" size', async () => {
    const it = (await t.http().post(api('/menu/items')).set(auth()).send({ categoryId: drinks.id, name: 'Lemon Soda', taxRuleId: tax.id, pricePaise: 6000 }).expect(201)).body;
    expect(it.variants).toEqual([expect.objectContaining({ name: 'Regular', pricePaise: 6000, isDefault: true })]);
    await t.http().patch(api(`/menu/items/${it.id}`)).set(auth()).send({ pricePaise: 6500 }).expect(200);
    const again = (await t.http().get(api(`/menu/items/${it.id}`)).set(auth()).expect(200)).body;
    expect(again.variants[0].pricePaise).toBe(6500);
  });

  it('editing sizes: update by code, add, retire (never delete), with the price change in the audit log; hubs pull it', async () => {
    const reg = (await t.http().post(api('/devices/register-hub')).set(auth()).send({ name: 'Hub', platform: 'android' }).expect(201)).body;
    const p0 = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', reg.deviceToken).expect(200)).body;
    const biryani = (await t.http().get(api('/menu/items')).set(auth()).expect(200)).body.find((i: { code: string }) => i.code === 'BIRYANI');
    const updated = (await t.http().put(api(`/menu/items/${biryani.id}/variants`)).set(auth()).send({
      variants: [
        { code: 'BIR-H', name: 'Half plate', portionLabel: 'half', pricePaise: 24000 },
        { code: 'BIR-F', name: 'Full plate', portionLabel: 'full', pricePaise: 42000, isDefault: true },
        { name: 'Family pack', portionLabel: 'custom', pricePaise: 90000, servingQuantity: 4, servingUnit: 'portion' },
      ],
    }).expect(200)).body;
    expect(updated.variants.map((v: { code: string; pricePaise: number }) => [v.code, v.pricePaise])).toEqual([['BIR-H', 24000], ['BIR-F', 42000], ['BIRYANI-FAMILYPACK', 90000]]);
    const retired = await t.owner.menuVariant.findFirstOrThrow({ where: { code: 'BIR-Q', tenantId: r.tenantId } });
    expect(retired).toMatchObject({ deleted: true, available: false });
    const audit = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'menu.variants_updated', objectId: biryani.id } });
    expect(audit.before).toEqual(expect.arrayContaining([expect.objectContaining({ code: 'BIR-H', pricePaise: 22000 })]));
    expect(audit.after).toEqual(expect.arrayContaining([expect.objectContaining({ code: 'BIR-H', pricePaise: 24000 })]));
    // a retired size comes back by its code (codes stay with their item and are never given to another)
    await t.http().put(api(`/menu/items/${biryani.id}/variants`)).set(auth()).send({ variants: [{ code: 'BIR-F', name: 'Full', pricePaise: 1 }, { code: 'BIR-Q', name: 'Q', pricePaise: 1 }] }).expect(200);
    const p1 = (await t.http().get(api(`/sync/pull?since=${p0.cursor}`)).set('X-Device-Token', reg.deviceToken).expect(200)).body;
    expect(p1.variants.some((v: { code: string; deleted: boolean }) => v.code === 'BIR-H' && v.deleted)).toBe(true);
    expect(p1.variants.find((v: { code: string }) => v.code === 'BIR-Q')).toMatchObject({ deleted: false, pricePaise: 1 });
  });

  it('categories: reorder, deactivate (hidden on the POS, items kept)', async () => {
    const starters = (await t.http().post(api('/menu/categories')).set(auth()).send({ name: 'Starters' }).expect(201)).body;
    const cats = (await t.http().get(api('/menu/categories')).set(auth()).expect(200)).body;
    const ids = [starters.id, ...cats.map((c: { id: string }) => c.id).filter((id: string) => id !== starters.id)];
    await t.http().put(api('/menu/categories/order')).set(auth()).send({ ids }).expect(200);
    const after = (await t.http().get(api('/menu/categories')).set(auth()).expect(200)).body;
    expect(after[0].id).toBe(starters.id);
    await t.http().patch(api(`/menu/categories/${drinks.id}`)).set(auth()).send({ active: false }).expect(200);
    expect((await t.http().get(api('/menu/categories')).set(auth()).expect(200)).body.find((c: { id: string }) => c.id === drinks.id).active).toBe(false);
    await t.http().put(api('/menu/categories/order')).set(bearer(other.ownerToken)).send({ ids }).expect(404); // another restaurant's ids
  });

  it('auditors and waiters read the menu but cannot change it; other restaurants cannot see it', async () => {
    const auditor = await addStaff(t, r.tenantId, 'auditor');
    const items = (await t.http().get(api('/menu/items')).set(bearer(auditor.token)).expect(200)).body;
    expect(items.length).toBeGreaterThan(0);
    await t.http().put(api(`/menu/items/${items[0].id}/variants`)).set(bearer(auditor.token)).send({ variants: [{ name: 'x', pricePaise: 1 }] }).expect(403);
    const waiter = await addStaff(t, r.tenantId, 'waiter');
    await t.http().post(api('/menu/items')).set(bearer(waiter.token)).send({ categoryId: drinks.id, name: 'x', taxRuleId: tax.id, pricePaise: 1 }).expect(403);
    expect((await t.http().get(api('/menu/items')).set(bearer(other.ownerToken)).expect(200)).body).toEqual([]);
    await t.http().get(api(`/menu/items/${items[0].id}`)).set(bearer(other.ownerToken)).expect(404);
  });
});
