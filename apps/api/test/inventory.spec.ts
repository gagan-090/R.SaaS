/** Inventory: products, the append-only ledger, unit conversion, costing, permissions, recipes and sale deductions. */
import { randomUUID } from 'crypto';
import { uuidv7 } from '../src/common/uuid';
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

describe('inventory', () => {
  let t: TestApp;
  let r: Awaited<ReturnType<typeof onboardRestaurant>>;
  let std: Awaited<ReturnType<typeof onboardRestaurant>>;
  let chef: { id: string; token: string };
  let auditor: { id: string; token: string };
  let rice: { id: string };
  let chicken: { id: string };
  let cola: { id: string };
  let cooler: { id: string };
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const owner = () => bearer(r.ownerToken);
  const key = () => randomUUID();
  const move = (tok: string, body: Record<string, unknown>) => t.http().post(api('/inventory/movements')).set(bearer(tok)).send({ idempotencyKey: key(), ...body });
  const stock = async (id: string) => (await t.http().get(api(`/inventory/products/${id}`)).set(owner()).expect(200)).body;

  beforeAll(async () => {
    t = await createTestApp();
    const sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    r = await onboardRestaurant(t, sa, 'premium');
    std = await onboardRestaurant(t, sa, 'standard');
    chef = await addStaff(t, r.tenantId, 'chef');
    auditor = await addStaff(t, r.tenantId, 'auditor');
    cooler = (await t.http().post(api('/inventory/locations')).set(owner()).send({ name: 'Walk-in cooler' }).expect(201)).body;
    rice = (await t.http().post(api('/inventory/products')).set(owner()).send({
      sku: 'RICE-BAS', name: 'Basmati rice', category: 'Grains', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 1000, unitCostPaise: 6000, minStock: 5000,
    }).expect(201)).body;
    chicken = (await t.http().post(api('/inventory/products')).set(owner()).send({
      sku: 'CHK-CURRY', name: 'Chicken (curry cut)', category: 'Meat', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 1000, unitCostPaise: 24000, defaultLocationId: cooler.id,
    }).expect(201)).body;
    cola = (await t.http().post(api('/inventory/products')).set(owner()).send({
      sku: 'COLA-500', name: 'Cola 500 ml bottle', category: 'Packaged drinks', baseUnit: 'bottle', purchaseUnit: 'case', conversionFactor: 24, unitCostPaise: 72000,
    }).expect(201)).body;
  });
  afterAll(() => t.close());

  it('products: unique SKU, known units, base unit locked once stock moves', async () => {
    await t.http().post(api('/inventory/products')).set(owner()).send({ sku: 'rice-bas', name: 'Dup', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 1000 }).expect(409);
    await t.http().post(api('/inventory/products')).set(owner()).send({ sku: 'X1', name: 'Bad', baseUnit: 'pound', purchaseUnit: 'kg', conversionFactor: 1 }).expect(400);
    await t.http().post(api('/inventory/products')).set(owner()).send({ sku: 'X2', name: 'Bad', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 0 }).expect(400);
    await t.http().post(api('/inventory/products')).set(bearer(chef.token)).send({ sku: 'X3', name: 'Chef', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 1000 }).expect(403);
  });

  it('opening stock and purchases: converted to base units, valued, averaged; a retry or a second opening adds nothing', async () => {
    const k = key();
    const o = (await t.http().post(api('/inventory/movements')).set(owner()).send({ idempotencyKey: k, type: 'opening', productId: rice.id, quantity: 25, unit: 'kg', unitCostPaise: 6000, batchNumber: 'B-1', expiryDate: '2027-01-31' }).expect(201)).body;
    expect(o.movements[0]).toMatchObject({ type: 'opening', quantity: 25000, valuePaise: 150000 });
    const again = (await t.http().post(api('/inventory/movements')).set(owner()).send({ idempotencyKey: k, type: 'opening', productId: rice.id, quantity: 25, unit: 'kg', unitCostPaise: 6000 }).expect(201)).body;
    expect(again).toMatchObject({ duplicate: true });
    expect((await move(r.ownerToken, { type: 'opening', productId: rice.id, quantity: 5, unit: 'kg' }).expect(409)).body.code).toBe('opening_exists');
    await move(r.ownerToken, { type: 'purchase', productId: rice.id, quantity: 10, unit: 'kg', unitCostPaise: 7000, reference: 'INV-778' }).expect(201);
    const s = await stock(rice.id);
    expect(s.stock).toBe(35000);
    expect(s.avgCostPaise).toBeCloseTo((25000 * 6 + 10000 * 7) / 35000, 2);
    expect(s.valuePaise).toBe(Math.round(35000 * ((25000 * 6 + 10000 * 7) / 35000)));
    // one case = 24 bottles
    await move(r.ownerToken, { type: 'opening', productId: cola.id, quantity: 2, unit: 'case', unitCostPaise: 72000 }).expect(201);
    expect((await stock(cola.id)).stock).toBe(48);
    await move(r.ownerToken, { type: 'opening', productId: chicken.id, quantity: 8, unit: 'kg', unitCostPaise: 24000 }).expect(201);
    expect((await stock(chicken.id)).byLocation).toEqual([{ locationId: cooler.id, quantity: 8000 }]);
  });

  it('kitchen use: the chef records consumption and wastage (with a reason), cannot receive stock, cannot go below zero', async () => {
    const c = (await move(chef.token, { type: 'consumption', productId: rice.id, quantity: 500, unit: 'g' }).expect(201)).body;
    expect(c.movements[0].quantity).toBe(-500);
    expect(c.movements[0].valuePaise).toBeLessThan(0);
    expect((await move(chef.token, { type: 'wastage', productId: rice.id, quantity: 200, unit: 'g' }).expect(400)).body.code).toBe('reason_required');
    await move(chef.token, { type: 'wastage', productId: rice.id, quantity: 200, unit: 'g', reason: 'Burnt batch' }).expect(201);
    expect((await move(chef.token, { type: 'purchase', productId: rice.id, quantity: 1, unit: 'kg' }).expect(403)).body.code).toBe('missing_permission');
    expect((await move(chef.token, { type: 'consumption', productId: rice.id, quantity: 999, unit: 'kg' }).expect(409)).body.code).toBe('insufficient_stock');
    expect((await move(chef.token, { type: 'consumption', productId: rice.id, quantity: 1, unit: 'l' }).expect(400)).body.code).toBe('incompatible_units');
    expect((await stock(rice.id)).stock).toBe(34300);
  });

  it('counts, adjustments, returns and transfers; every movement is in the history with actor and reason', async () => {
    const cnt = (await move(r.ownerToken, { type: 'count', productId: rice.id, quantity: 34, unit: 'kg', reason: 'Monthly count' }).expect(201)).body;
    expect(cnt.movements[0]).toMatchObject({ type: 'count_adjustment', quantity: -300 });
    await move(r.ownerToken, { type: 'adjustment', productId: rice.id, quantity: -1, unit: 'kg', reason: 'Spilled sack' }).expect(201);
    await move(r.ownerToken, { type: 'return_to_supplier', productId: rice.id, quantity: 1, unit: 'kg', reason: 'Wrong grade' }).expect(201);
    const tr = (await move(r.ownerToken, { type: 'transfer', productId: chicken.id, quantity: 2, unit: 'kg', locationId: cooler.id, toLocationId: null }).expect(400)).body;
    expect(tr.code).toBe('transfer_target');
    const dry = (await t.http().post(api('/inventory/locations')).set(owner()).send({ name: 'Dry store' }).expect(201)).body;
    await move(r.ownerToken, { type: 'transfer', productId: chicken.id, quantity: 2, unit: 'kg', locationId: cooler.id, toLocationId: dry.id }).expect(201);
    const ch = await stock(chicken.id);
    expect(ch.stock).toBe(8000);
    expect(ch.byLocation).toEqual(expect.arrayContaining([{ locationId: cooler.id, quantity: 6000 }, { locationId: dry.id, quantity: 2000 }]));
    const hist = (await t.http().get(api(`/inventory/movements?productId=${rice.id}`)).set(owner()).expect(200)).body;
    expect(hist.map((m: { type: string }) => m.type)).toEqual(expect.arrayContaining(['opening', 'purchase', 'consumption', 'wastage', 'count_adjustment', 'adjustment', 'return_to_supplier']));
    expect(hist.find((m: { type: string }) => m.type === 'wastage')).toMatchObject({ reason: 'Burnt batch', actorRole: 'chef' });
    expect((await stock(rice.id)).stock).toBe(32000);
  });

  it('the ledger cannot be edited or deleted, even by the database owner', async () => {
    const m = await t.owner.stockMovement.findFirstOrThrow({ where: { productId: rice.id } });
    await expect(t.owner.stockMovement.update({ where: { id: m.id }, data: { reason: 'tampered' } })).rejects.toThrow(/append-only/);
    await expect(t.owner.stockMovement.delete({ where: { id: m.id } })).rejects.toThrow(/append-only/);
  });

  it('recipes per size; a paid bill deducts once (retries and repeated bill events add nothing); reversed lines and refunds do not', async () => {
    const tax = (await t.http().post(api('/tax-rules')).set(owner()).send({ name: 'GST 5%', rateBp: 500 }).expect(201)).body;
    const cat = (await t.http().post(api('/menu/categories')).set(owner()).send({ name: 'Main Course' }).expect(201)).body;
    const biryani = (await t.http().post(api('/menu/items')).set(owner()).send({
      categoryId: cat.id, code: 'BIR', name: 'Biryani', taxRuleId: tax.id,
      variants: [
        { code: 'BIR-H', name: 'Half plate', portionRatio: 0.5, pricePaise: 22000 },
        { code: 'BIR-F', name: 'Full plate', portionRatio: 1, pricePaise: 40000, isDefault: true },
      ],
    }).expect(201)).body;
    const drinks = (await t.http().post(api('/menu/categories')).set(owner()).send({ name: 'Soft Drinks' }).expect(201)).body;
    const colaItem = (await t.http().post(api('/menu/items')).set(owner()).send({ categoryId: drinks.id, code: 'COLA', name: 'Cola', taxRuleId: tax.id, variants: [{ code: 'COLA-500ML', name: '500 ml', pricePaise: 5000 }] }).expect(201)).body;
    const full = biryani.variants.find((v: { code: string }) => v.code === 'BIR-F');
    const half = biryani.variants.find((v: { code: string }) => v.code === 'BIR-H');
    // only the full plate has a recipe: the half plate uses it × 0.5 by default
    await t.http().put(api(`/menu/variants/${full.id}/recipe`)).set(owner()).send({ lines: [{ productId: rice.id, quantity: 0.3, unit: 'kg' }, { productId: chicken.id, quantity: 250, unit: 'g' }] }).expect(200);
    await t.http().put(api(`/menu/variants/${colaItem.variants[0].id}/recipe`)).set(owner()).send({ lines: [{ productId: cola.id, quantity: 1, unit: 'bottle' }] }).expect(200);
    await t.http().put(api(`/menu/variants/${half.id}/recipe`)).set(owner()).send({ lines: [{ productId: rice.id, quantity: 1, unit: 'l' }] }).expect(400); // incompatible
    const hr = (await t.http().get(api(`/menu/variants/${half.id}/recipe`)).set(owner()).expect(200)).body;
    expect(hr).toMatchObject({ own: false, lines: expect.arrayContaining([expect.objectContaining({ productId: rice.id, quantity: 0.15, unit: 'kg' })]) });
    expect(hr.costPaise).toBeGreaterThan(0);
    await t.http().put(api(`/menu/variants/${half.id}/recipe`)).set(bearer(chef.token)).send({ lines: [] }).expect(403);

    const before = { rice: (await stock(rice.id)).stock, chicken: (await stock(chicken.id)).stock, cola: (await stock(cola.id)).stock };
    const reg = (await t.http().post(api('/devices/register-hub')).set(owner()).send({ name: 'Hub', platform: 'android' }).expect(201)).body;
    const o = uuidv7(), b = uuidv7(), l1 = uuidv7(), l2 = uuidv7(), l3 = uuidv7();
    const ev = (entity: string, id: string, payload: Record<string, unknown>) => ({ eventId: uuidv7(), entity, entityId: id, op: 'upsert', payload: { ...payload, branchId: r.branchId }, createdAt: new Date().toISOString() });
    const events = [
      ev('order', o, { id: o, type: 'takeaway', status: 'open' }),
      ev('order_line', l1, { id: l1, order_id: o, menu_item_id: biryani.id, variant_id: half.id, name_snapshot: 'Biryani · Half plate', qty: 2, status: 'sent' }),
      ev('order_line', l2, { id: l2, order_id: o, menu_item_id: colaItem.id, variant_id: colaItem.variants[0].id, name_snapshot: 'Cola', qty: 3, status: 'sent' }),
      ev('order_line', l3, { id: l3, order_id: o, menu_item_id: biryani.id, variant_id: full.id, name_snapshot: 'Biryani · Full plate', qty: 1, status: 'reversed' }),
      ev('bill', b, { id: b, order_id: o, status: 'paid', total_paise: 59000 }),
    ];
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events }).expect(200);
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events }).expect(200); // retried push
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events: [ev('bill', b, { id: b, order_id: o, status: 'paid', tip_paise: 1000 })] }).expect(200);
    // a refund adjustment on the paid bill does not restore stock
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events: [ev('bill_adjustment', uuidv7(), { bill_id: b, amount_paise: -5000, reason: 'Refund' })] }).expect(200);
    const after = { rice: (await stock(rice.id)).stock, chicken: (await stock(chicken.id)).stock, cola: (await stock(cola.id)).stock };
    expect(before.rice - after.rice).toBe(300); // 2 half plates × 150 g
    expect(before.chicken - after.chicken).toBe(250); // 2 × 125 g
    expect(before.cola - after.cola).toBe(3);
    const sales = await t.owner.stockMovement.findMany({ where: { tenantId: r.tenantId, type: 'sale' } });
    expect(sales).toHaveLength(3);
    expect(new Set(sales.map((s) => s.sourceId))).toEqual(new Set([l1, l2]));
  });

  it('alerts: low stock, expiring batches; valuation by category', async () => {
    await move(r.ownerToken, { type: 'purchase', productId: chicken.id, quantity: 1, unit: 'kg', unitCostPaise: 24000, batchNumber: 'CH-9', expiryDate: new Date(Date.now() + 2 * 86_400_000).toISOString().slice(0, 10) }).expect(201);
    await t.http().patch(api(`/inventory/products/${cola.id}`)).set(owner()).send({ minStock: 100 }).expect(200);
    const al = (await t.http().get(api('/inventory/alerts')).set(bearer(chef.token)).expect(200)).body;
    expect(al.low.map((x: { sku: string }) => x.sku)).toContain('COLA-500');
    expect(al.expiring).toEqual([expect.objectContaining({ sku: 'CHK-CURRY', batchNumber: 'CH-9', expired: false })]);
    const val = (await t.http().get(api('/inventory/valuation')).set(bearer(auditor.token)).expect(200)).body;
    expect(val.method).toMatch(/weighted-average/);
    expect(val.byCategory.map((c: { category: string }) => c.category)).toEqual(expect.arrayContaining(['Grains', 'Meat', 'Packaged drinks']));
    expect(val.totalPaise).toBe(val.products.reduce((s: number, p: { valuePaise: number }) => s + p.valuePaise, 0));
  });

  it('replenishment: the chef asks, the owner orders and receives; the chef cannot approve', async () => {
    const q = (await t.http().post(api('/inventory/requests')).set(bearer(chef.token)).send({ productId: rice.id, quantity: 10, unit: 'kg', note: 'For the weekend' }).expect(201)).body;
    await t.http().patch(api(`/inventory/requests/${q.id}`)).set(bearer(chef.token)).send({ status: 'ordered' }).expect(403);
    await t.http().patch(api(`/inventory/requests/${q.id}`)).set(owner()).send({ status: 'ordered' }).expect(200);
    await t.http().patch(api(`/inventory/requests/${q.id}`)).set(owner()).send({ status: 'received' }).expect(200);
    await t.http().patch(api(`/inventory/requests/${q.id}`)).set(owner()).send({ status: 'cancelled' }).expect(409);
    expect((await t.http().get(api('/inventory/requests')).set(bearer(chef.token)).expect(200)).body[0]).toMatchObject({ status: 'received', requestedByName: 'chef' });
  });

  it('expenses: recorded in paise, voided with a reason (never deleted); auditors read but cannot write', async () => {
    const e = (await t.http().post(api('/expenses')).set(owner()).send({ category: 'Utilities', description: 'Electricity October', amountPaise: 1234500, paidOn: '2026-10-10', paymentMode: 'bank', reference: 'MSEB-77' }).expect(201)).body;
    await t.http().post(api('/expenses')).set(owner()).send({ category: 'Rent', description: 'x', amountPaise: 10.5, paidOn: '2026-10-10', paymentMode: 'bank' }).expect(400);
    await t.http().post(api('/expenses')).set(bearer(auditor.token)).send({ category: 'Rent', description: 'x', amountPaise: 100, paidOn: '2026-10-10', paymentMode: 'cash' }).expect(403);
    const list = (await t.http().get(api('/expenses')).set(bearer(auditor.token)).expect(200)).body;
    expect(list.totalPaise).toBe(1234500);
    await t.http().post(api(`/expenses/${e.id}/void`)).set(owner()).send({}).expect(400);
    await t.http().post(api(`/expenses/${e.id}/void`)).set(owner()).send({ reason: 'Entered twice' }).expect(200);
    await t.http().post(api(`/expenses/${e.id}/void`)).set(owner()).send({ reason: 'Again' }).expect(409);
    expect((await t.http().get(api('/expenses')).set(owner()).expect(200)).body.totalPaise).toBe(0);
    expect((await t.http().get(api('/expenses?includeVoided=true')).set(owner()).expect(200)).body.items[0]).toMatchObject({ voidReason: 'Entered twice' });
  });

  it('auditors read stock and history but post nothing; other restaurants see nothing; plans without inventory refuse changes', async () => {
    await t.http().get(api('/inventory/movements')).set(bearer(auditor.token)).expect(200);
    expect((await move(auditor.token, { type: 'consumption', productId: rice.id, quantity: 1, unit: 'g' }).expect(403)).body.code).toBe('missing_permission');
    await t.http().post(api('/inventory/requests')).set(bearer(auditor.token)).send({ productId: rice.id, quantity: 1, unit: 'kg' }).expect(403);
    expect((await t.http().get(api('/inventory/products')).set(bearer(std.ownerToken)).expect(403)).body.code).toBe('feature_not_in_plan');
    await t.http().get(api(`/inventory/products/${rice.id}`)).set(bearer(r.ownerToken)).expect(200);
    const sp = await t.http().post(api('/inventory/products')).set(bearer(std.ownerToken)).send({ sku: 'S1', name: 's', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 1000 }).expect(403);
    expect(sp.body.code).toBe('feature_not_in_plan');
    // a premium owner cannot touch another restaurant's product
    const other = await onboardRestaurant(t, (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken, 'premium');
    await t.http().get(api(`/inventory/products/${rice.id}`)).set(bearer(other.ownerToken)).expect(404);
    expect((await move(other.ownerToken, { type: 'opening', productId: rice.id, quantity: 1, unit: 'kg' }).expect(404)).body.code).toBe('not_found');
  });
});
