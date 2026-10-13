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

  describe('staff', () => {
    it('owner adds a waiter with a PIN; the hub receives them on the next pull; PIN never in audit', async () => {
      const reg = (await t.http().post(api('/devices/register-hub')).set(bearer(prem.ownerToken)).send({ name: 'Hub', platform: 'android' }).expect(201)).body;
      const p0 = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', reg.deviceToken).expect(200)).body;
      const w = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Anita', role: 'waiter', pin: '4321' }).expect(201)).body;
      expect(w).toMatchObject({ name: 'Anita', role: 'waiter', status: 'active' });
      const p1 = (await t.http().get(api(`/sync/pull?since=${p0.cursor}`)).set('X-Device-Token', reg.deviceToken).expect(200)).body;
      const pulled = p1.users.find((u: { id: string }) => u.id === w.id);
      expect(pulled.roles).toEqual([{ role: 'waiter', extraPermissions: [] }]);
      expect(pulled.pinHash).toMatch(/^\$argon2id\$v=19\$m=19456,p=1,t=2\$/); // node-argon2 PHC string — the hub verifies it offline (hub_test)
      const audit = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'staff.created', objectId: w.id } });
      expect(JSON.stringify(audit)).not.toContain('4321');
      const list = (await t.http().get(api('/staff')).set(bearer(prem.ownerToken)).expect(200)).body;
      expect(list.find((u: { id: string }) => u.id === w.id)).toMatchObject({ role: 'waiter', hasPin: true });
    });

    it('PIN change, cashier discount grant, and disabling flow to the hub; the owner cannot be disabled', async () => {
      const c = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Ravi', role: 'cashier', pin: '1111' }).expect(201)).body;
      await t.http().patch(api(`/staff/${c.id}`)).set(bearer(prem.ownerToken)).send({ pin: '2222', canDiscount: true }).expect(200);
      const row = await t.owner.user.findUniqueOrThrow({ where: { id: c.id }, include: { roles: true } });
      expect(row.roles[0].extraPermissions).toEqual(['discount.apply']);
      await t.http().patch(api(`/staff/${c.id}`)).set(bearer(prem.ownerToken)).send({ status: 'disabled' }).expect(200);
      expect((await t.owner.user.findUniqueOrThrow({ where: { id: c.id } })).status).toBe('disabled');
      const r = await t.http().patch(api(`/staff/${prem.ownerUserId}`)).set(bearer(prem.ownerToken)).send({ status: 'disabled' }).expect(403);
      expect(r.body.code).toBe('owner_protected');
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'x', role: 'waiter', pin: '12' }).expect(400);
    });

    it('chef / IT admin / auditor need Premium; standard owners can add cashiers and waiters', async () => {
      const r = await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Kunal', role: 'chef', pin: '7777' }).expect(403);
      expect(r.body.code).toBe('feature_not_in_plan');
      await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Sohan', role: 'waiter', pin: '5555' }).expect(201);
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Kunal', role: 'chef', pin: '7777' }).expect(201);
    });

    it('an IT admin with console sign-in can be added by the owner and can then manage staff, but not other IT admins', async () => {
      const email = `it-${uuidv7().slice(-8)}@example.test`;
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Imran', role: 'it_admin', pin: '3333', email }).expect(400); // password required
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Imran', role: 'it_admin', pin: '3333', email, password: 'It-admin-pass-1' }).expect(201);
      const it = (await t.http().post(api('/auth/login')).send({ email, password: 'It-admin-pass-1' }).expect(200)).body;
      await t.http().post(api('/staff')).set(bearer(it.accessToken)).send({ name: 'Sohan', role: 'waiter', pin: '6666' }).expect(201);
      const r = await t.http().post(api('/staff')).set(bearer(it.accessToken)).send({ name: 'Other IT', role: 'it_admin', pin: '6666' }).expect(403);
      expect(r.body.code).toBe('owner_only');
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'dup', role: 'waiter', pin: '1234', email, password: 'whatever-123' }).expect(409);
    });

    it('cashiers cannot manage staff', async () => {
      const cashier = await addStaff(t, prem.tenantId, 'cashier');
      await t.http().post(api('/staff')).set(bearer(cashier.token)).send({ name: 'x', role: 'waiter', pin: '1234' }).expect(403);
      await t.http().get(api('/staff')).set(bearer(cashier.token)).expect(403);
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

  it('dashboard totals come from synced bills (latest version), payments, lines and tips', async () => {
    const reg = (await t.http().post(api('/devices/register-hub')).set(bearer(std.ownerToken)).send({ name: 'Hub 3', platform: 'windows' }).expect(201)).body;
    const now = new Date().toISOString();
    const billId = uuidv7();
    const e = (entity: string, entityId: string, op: string, payload: Record<string, unknown>) => ({ eventId: uuidv7(), entity, entityId, op, payload: { ...payload, branchId: std.branchId }, createdAt: now });
    const events = [
      e('order', uuidv7(), 'create', {}),
      e('order_line', uuidv7(), 'create', { name_snapshot: 'Butter Chicken', qty: 2, price_snapshot_paise: 34000, status: 'sent' }),
      e('order_line', uuidv7(), 'create', { name_snapshot: 'Naan', qty: 3, price_snapshot_paise: 6000, status: 'reversed' }),
      e('bill', billId, 'create', { status: 'open', total_paise: 71400, created_at: now }),
      e('bill', billId, 'update', { status: 'paid', total_paise: 74400, cgst_paise: 1700, sgst_paise: 1700, discount_paise: 0, created_at: now, closed_at: now }),
      e('payment', uuidv7(), 'create', { mode: 'upi', amountPaise: 40000 }),
      e('payment', uuidv7(), 'create', { mode: 'cash', amountPaise: 34400 }),
      e('tip_allocation', uuidv7(), 'create', { amountPaise: 3000 }),
    ];
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events }).expect(200);
    const d = (await t.http().get(api('/tenant/dashboard?days=7')).set(bearer(std.ownerToken)).expect(200)).body;
    expect(d.today).toEqual({ salesPaise: 74400, bills: 1, avgBillPaise: 74400 });
    expect(d.period).toMatchObject({ salesPaise: 74400, bills: 1, orders: 1, taxesPaise: 3400, tipsPaise: 3000 });
    expect(d.byMode).toEqual({ upi: 40000, cash: 34400 });
    expect(d.topItems).toEqual([{ name: 'Butter Chicken', qty: 2, amountPaise: 68000 }]); // reversed lines excluded
    expect(d.days).toHaveLength(7);
    expect(d.days.at(-1).salesPaise).toBe(74400);
    const cashier = await addStaff(t, std.tenantId, 'cashier');
    await t.http().get(api('/tenant/dashboard')).set(bearer(cashier.token)).expect(403);
  });
});
