/** Restaurant console: overview, staff with PINs, devices & hubs, menu photos/deletes, sales dashboard — and that the hub sees it all on pull. */
import { uuidv7 } from '../src/common/uuid';
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

// 1×1 transparent PNG (valid magic bytes) padded with a harmless tEXt-like tail so it passes the 64-byte minimum
const PNG = Buffer.concat([
  Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63fcffff3f0300050001ff5a4a6b1f0000000049454e44ae426082', 'hex'),
  Buffer.alloc(32, 0),
]).toString('base64');

describe('restaurant console', () => {
  let t: TestApp;
  let std: Awaited<ReturnType<typeof onboardRestaurant>>;
  let prem: Awaited<ReturnType<typeof onboardRestaurant>>;
  let saToken: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    const sa = await createAdmin(t, ['Super Admin']);
    saToken = (await loginAdmin(t, sa)).accessToken;
    std = await onboardRestaurant(t, saToken, 'standard');
    prem = await onboardRestaurant(t, saToken, 'premium');
  });
  afterAll(() => t.close());

  it('overview shows the restaurant, branch, plan and counts', async () => {
    const o = (await t.http().get(api('/tenant/overview')).set(bearer(prem.ownerToken)).expect(200)).body;
    expect(o.restaurant.id).toBe(prem.tenantId);
    expect(o.branches).toEqual([expect.objectContaining({ id: prem.branchId, code: 'BR01' })]);
    expect(o.license).toMatchObject({ plan: 'premium', state: 'active' });
    expect(o.counts).toMatchObject({ staff: 1, devices: 0 });
    expect(o.hub).toBeNull();
  });

  describe('own PIN', () => {
    it('an owner without a PIN (signed up on the web) sets their own; /me reports it and the PIN never reaches audit', async () => {
      await t.owner.user.update({ where: { id: std.ownerUserId }, data: { pinHash: null } });
      expect((await t.http().get(api('/me')).set(bearer(std.ownerToken)).expect(200)).body).toMatchObject({ hasPin: false });
      await t.http().put(api('/me/pin')).set(bearer(std.ownerToken)).send({ pin: '12' }).expect(400);
      await t.http().put(api('/me/pin')).set(bearer(std.ownerToken)).send({ pin: '123456' }).expect(400); // too simple
      await t.http().put(api('/me/pin')).set(bearer(std.ownerToken)).send({ pin: '246813' }).expect(200);
      const me = (await t.http().get(api('/me')).set(bearer(std.ownerToken)).expect(200)).body;
      expect(me.hasPin).toBe(true);
      expect(me.pinHash).toBeUndefined();
      const audit = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'staff.pin_set', objectId: std.ownerUserId } });
      expect(JSON.stringify(audit)).not.toContain('246813');
    });
  });

  describe('devices & hubs', () => {
    it('lists the hub and revokes a device with a reason; a revoked hub can no longer sync', async () => {
      const reg = (await t.http().post(api('/devices/register-hub')).set(bearer(std.ownerToken)).send({ name: 'Cashier phone', platform: 'android' }).expect(201)).body;
      await t.http().get(api('/sync/status')).set('X-Device-Token', reg.deviceToken).expect(200);
      const list = (await t.http().get(api('/devices')).set(bearer(std.ownerToken)).expect(200)).body;
      expect(list[0]).toMatchObject({ id: reg.deviceId, name: 'Cashier phone', isHub: true, online: true, branch: { code: 'BR01' } });
      await t.http().post(api(`/devices/${reg.deviceId}/revoke`)).set(bearer(std.ownerToken)).send({}).expect(400);
      await t.http().post(api(`/devices/${reg.deviceId}/revoke`)).set(bearer(std.ownerToken)).send({ reason: 'phone lost' }).expect(200);
      await t.http().get(api('/sync/status')).set('X-Device-Token', reg.deviceToken).expect(401);
      const again = await t.http().post(api(`/devices/${reg.deviceId}/revoke`)).set(bearer(std.ownerToken)).send({ reason: 'again' }).expect(409);
      expect(again.body.code).toBe('already_revoked');
    });
  });

  describe('menu', () => {
    let cat: { id: string };
    let item: { id: string };
    let device: string;
    beforeAll(async () => {
      const auth = bearer(prem.ownerToken);
      const tax = (await t.http().post(api('/tax-rules')).set(auth).send({ name: 'GST 5%', rateBp: 500 }).expect(201)).body;
      cat = (await t.http().post(api('/menu/categories')).set(auth).send({ name: 'Mains' }).expect(201)).body;
      item = (await t.http().post(api('/menu/items')).set(auth).send({ categoryId: cat.id, name: 'Dal Makhani', pricePaise: 22000, taxRuleId: tax.id }).expect(201)).body;
      device = (await t.http().post(api('/devices/register-hub')).set(auth).send({ name: 'Hub 2', platform: 'windows' }).expect(201)).body.deviceToken;
    });

    it('a photo uploads, is served publicly with caching, and reaches the hub as imageId', async () => {
      const auth = bearer(prem.ownerToken);
      await t.http().put(api(`/menu/items/${item.id}/image`)).set(auth).send({ contentType: 'image/jpeg', dataBase64: PNG }).expect(400); // magic bytes checked
      const r = (await t.http().put(api(`/menu/items/${item.id}/image`)).set(auth).send({ contentType: 'image/png', dataBase64: PNG }).expect(200)).body;
      const img = await t.http().get(api(`/media/${r.imageId}`)).expect(200);
      expect(img.headers['content-type']).toBe('image/png');
      expect(img.headers['cache-control']).toContain('immutable');
      expect(Buffer.from(img.body).subarray(0, 4).toString('hex')).toBe('89504e47');
      const pull = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', device).expect(200)).body;
      expect(pull.items.find((i: { id: string }) => i.id === item.id).imageId).toBe(r.imageId);
      // replacing the photo deletes the old bytes
      const r2 = (await t.http().put(api(`/menu/items/${item.id}/image`)).set(auth).send({ contentType: 'image/png', dataBase64: PNG }).expect(200)).body;
      await t.http().get(api(`/media/${r.imageId}`)).expect(404);
      await t.http().delete(api(`/menu/items/${item.id}/image`)).set(auth).expect(204);
      await t.http().get(api(`/media/${r2.imageId}`)).expect(404);
      // another restaurant cannot touch this item
      await t.http().put(api(`/menu/items/${item.id}/image`)).set(bearer(std.ownerToken)).send({ contentType: 'image/png', dataBase64: PNG }).expect(404);
    });

    it('categories rename; a non-empty category cannot be deleted; a deleted dish is a tombstone the hub pulls', async () => {
      const auth = bearer(prem.ownerToken);
      const p0 = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', device).expect(200)).body;
      expect((await t.http().patch(api(`/menu/categories/${cat.id}`)).set(auth).send({ name: 'Main course' }).expect(200)).body.name).toBe('Main course');
      expect((await t.http().delete(api(`/menu/categories/${cat.id}`)).set(auth).expect(409)).body.code).toBe('category_not_empty');
      await t.http().delete(api(`/menu/items/${item.id}`)).set(auth).expect(204);
      const p1 = (await t.http().get(api(`/sync/pull?since=${p0.cursor}`)).set('X-Device-Token', device).expect(200)).body;
      expect(p1.items.find((i: { id: string }) => i.id === item.id)).toMatchObject({ deleted: true });
      await t.http().delete(api(`/menu/categories/${cat.id}`)).set(auth).expect(204);
      expect((await t.http().get(api('/menu/categories')).set(auth).expect(200)).body.map((c: { id: string }) => c.id)).not.toContain(cat.id);
    });

    it('a floor with tables cannot be deleted; an empty one can', async () => {
      const auth = bearer(prem.ownerToken);
      const f = (await t.http().post(api('/floors')).set(auth).send({ branchId: prem.branchId, name: 'Roof' }).expect(201)).body;
      const tb = (await t.http().post(api('/tables')).set(auth).send({ floorId: f.id, name: 'R1' }).expect(201)).body;
      expect((await t.http().delete(api(`/floors/${f.id}`)).set(auth).expect(409)).body.code).toBe('floor_not_empty');
      await t.http().delete(api(`/tables/${tb.id}`)).set(auth).expect(204);
      await t.http().delete(api(`/floors/${f.id}`)).set(auth).expect(204);
    });
  });

  it('dashboard: KPIs, previous period, hourly, dine-in vs takeaway, categories, waiters, reversals, live, recent bills, bill detail', async () => {
    const auth = bearer(std.ownerToken);
    const reg = (await t.http().post(api('/devices/register-hub')).set(auth).send({ name: 'Hub 3', platform: 'windows' }).expect(201)).body;
    const tax = (await t.http().post(api('/tax-rules')).set(auth).send({ name: 'GST 5%', rateBp: 500 }).expect(201)).body;
    const mains = (await t.http().post(api('/menu/categories')).set(auth).send({ name: 'Mains' }).expect(201)).body;
    const chicken = (await t.http().post(api('/menu/items')).set(auth).send({ categoryId: mains.id, name: 'Butter Chicken', pricePaise: 34000, taxRuleId: tax.id }).expect(201)).body;
    const waiter = (await t.http().post(api('/staff')).set(auth).send({ name: 'Anita', email: `anita-${uuidv7().slice(-8)}@example.test`, role: 'waiter', sendInvite: true }).expect(201)).body;
    const floor = (await t.http().post(api('/floors')).set(auth).send({ branchId: std.branchId, name: 'Ground' }).expect(201)).body;
    const table = (await t.http().post(api('/tables')).set(auth).send({ floorId: floor.id, name: '7' }).expect(201)).body;

    const now = new Date().toISOString();
    const yesterday = new Date(Date.now() - 86_400_000).toISOString();
    const ids = { o1: uuidv7(), o2: uuidv7(), o3: uuidv7(), b1: uuidv7(), b2: uuidv7(), b0: uuidv7(), l1: uuidv7(), l2: uuidv7(), l3: uuidv7() };
    const e = (entity: string, entityId: string, op: string, payload: Record<string, unknown>, at = now) => ({ eventId: uuidv7(), entity, entityId, op, payload: { ...payload, branchId: std.branchId }, createdAt: at });
    const events = [
      // dine-in on table 7 for Anita: 2 butter chicken, 3 naan reversed; billed and paid UPI + cash, tip 30
      e('order', ids.o1, 'create', { id: ids.o1, type: 'dine_in', table_id: table.id, waiter_id: waiter.id, status: 'open', opened_at: now }),
      e('order_line', ids.l1, 'create', { id: ids.l1, order_id: ids.o1, menu_item_id: chicken.id, name_snapshot: 'Butter Chicken', qty: 2, price_snapshot_paise: 34000, status: 'sent', created_at: now }),
      e('order_line', ids.l2, 'create', { id: ids.l2, order_id: ids.o1, menu_item_id: uuidv7(), name_snapshot: 'Naan', qty: 3, price_snapshot_paise: 6000, status: 'sent', created_at: now }),
      e('order_line', ids.l2, 'update', { id: ids.l2, order_id: ids.o1, name_snapshot: 'Naan', qty: 3, price_snapshot_paise: 6000, status: 'reversed', reversal_reason: 'Guest changed mind', reversed_at: now }),
      e('bill', ids.b1, 'create', { id: ids.b1, order_id: ids.o1, invoice_no: 'BR01/26-27/000101', status: 'open', total_paise: 71400, created_at: now }),
      e('bill', ids.b1, 'update', { id: ids.b1, order_id: ids.o1, invoice_no: 'BR01/26-27/000101', status: 'paid', subtotal_paise: 68000, discount_paise: 0, total_paise: 74400, cgst_paise: 1700, sgst_paise: 1700, tip_paise: 3000, round_off_paise: 0, created_at: now, closed_at: now }),
      e('payment', uuidv7(), 'create', { billId: ids.b1, mode: 'upi', amountPaise: 40000, at: now }),
      e('payment', uuidv7(), 'create', { billId: ids.b1, mode: 'cash', amountPaise: 34400, tenderedPaise: 50000, changePaise: 15600, at: now }),
      e('tip_allocation', uuidv7(), 'create', { billId: ids.b1, waiterId: waiter.id, amountPaise: 3000 }),
      e('bill_adjustment', uuidv7(), 'create', { bill_id: ids.b1, amount_paise: -2000, reason: 'Naan was cold', at: now }),
      // takeaway, paid by card
      e('order', ids.o2, 'create', { id: ids.o2, type: 'takeaway', status: 'paid', opened_at: now }),
      e('order_line', ids.l3, 'create', { id: ids.l3, order_id: ids.o2, menu_item_id: chicken.id, name_snapshot: 'Butter Chicken', qty: 1, price_snapshot_paise: 34000, status: 'sent', created_at: now }),
      e('bill', ids.b2, 'update', { id: ids.b2, order_id: ids.o2, invoice_no: 'BR01/26-27/000102', status: 'paid', total_paise: 35700, cgst_paise: 850, sgst_paise: 850, created_at: now, closed_at: now }),
      e('payment', uuidv7(), 'create', { billId: ids.b2, mode: 'card', amountPaise: 35700, at: now }),
      // still open on a table right now
      e('order', ids.o3, 'create', { id: ids.o3, type: 'dine_in', table_id: table.id, status: 'open', opened_at: now }),
      // yesterday: one bill for the comparison
      e('bill', ids.b0, 'update', { id: ids.b0, order_id: uuidv7(), invoice_no: 'BR01/26-27/000100', status: 'paid', total_paise: 50000, created_at: yesterday, closed_at: yesterday }, yesterday),
    ];
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events }).expect(200);

    const d = (await t.http().get(api('/tenant/dashboard?range=today')).set(auth).expect(200)).body;
    expect(d.kpis).toMatchObject({
      salesPaise: 110100, bills: 2, avgBillPaise: 55050, dineInPaise: 74400, takeawayPaise: 35700, dineInBills: 1, takeawayBills: 1,
      taxesPaise: 5100, tipsPaise: 3000, reversals: { count: 1, amountPaise: 18000 }, adjustments: { count: 1, amountPaise: -2000 },
    });
    expect(d.previous).toMatchObject({ salesPaise: 50000, bills: 1 });
    expect(d.change.salesPct).toBe(120.2);
    expect(d.byMode).toEqual({ upi: 40000, cash: 34400, card: 35700 });
    expect(d.byCategory).toEqual([{ name: 'Mains', qty: 3, amountPaise: 102000 }]);
    expect(d.topItems[0]).toEqual({ name: 'Butter Chicken', category: 'Mains', qty: 3, amountPaise: 102000 });
    expect(d.byWaiter).toEqual(expect.arrayContaining([
      { name: 'Anita', salesPaise: 74400, bills: 1, tipsPaise: 3000 },
      { name: 'No waiter', salesPaise: 35700, bills: 1, tipsPaise: 0 },
    ]));
    expect(d.reversals.reasons).toEqual([{ reason: 'Guest changed mind', count: 1 }]);
    expect(d.live).toMatchObject({ openTables: 1, takeaways: 0 });
    expect(d.hourly).toHaveLength(24);
    expect(d.hourly.reduce((s: number, h: { salesPaise: number }) => s + h.salesPaise, 0)).toBe(110100);
    expect(d.recentBills[0]).toMatchObject({ invoiceNo: expect.stringMatching(/^BR01\/26-27\/00010[12]$/), status: 'paid' });
    expect(d.recentBills.find((b: { id: string }) => b.id === ids.b1)).toMatchObject({ where: 'Table 7', waiter: 'Anita' });
    // legacy keys still there for older clients
    expect(d.today).toEqual({ salesPaise: 110100, bills: 2, avgBillPaise: 55050 });

    const week = (await t.http().get(api('/tenant/dashboard?range=7d')).set(auth).expect(200)).body;
    expect(week.series).toHaveLength(7);
    expect(week.kpis.salesPaise).toBe(160100);

    const bill = (await t.http().get(api(`/tenant/bills/${ids.b1}`)).set(auth).expect(200)).body;
    expect(bill).toMatchObject({ invoiceNo: 'BR01/26-27/000101', where: 'Table 7', waiter: 'Anita', status: 'paid', totals: { totalPaise: 74400 } });
    expect(bill.lines).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: 'Butter Chicken', qty: 2, amountPaise: 68000, status: 'sent' }),
      expect.objectContaining({ name: 'Naan', status: 'reversed', reversalReason: 'Guest changed mind' }),
    ]));
    expect(bill.payments.map((p: { mode: string }) => p.mode)).toEqual(['upi', 'cash']);
    expect(bill.tips).toEqual([{ waiter: 'Anita', amountPaise: 3000 }]);
    expect(bill.adjustments).toEqual([expect.objectContaining({ amountPaise: -2000, reason: 'Naan was cold' })]);
    await t.http().get(api(`/tenant/bills/${uuidv7()}`)).set(auth).expect(404);

    const cashier = await addStaff(t, std.tenantId, 'cashier');
    await t.http().get(api('/tenant/dashboard')).set(bearer(cashier.token)).expect(403);
    await t.http().get(api(`/tenant/bills/${ids.b1}`)).set(bearer(cashier.token)).expect(403);
  });
});
