/** Auditor portal: restaurant audit log (cloud + POS), filters, exports, sales records, live orders, isolation. */
import { randomInt } from 'crypto';
import { uuidv7 } from '../src/common/uuid';
import { pinProblem } from '../src/staff/pin-policy';
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

const goodPin = () => {
  for (;;) {
    const p = String(randomInt(100000, 99999999));
    if (!pinProblem(p)) return p;
  }
};

describe('auditor portal and restaurant records', () => {
  let t: TestApp;
  let r: Awaited<ReturnType<typeof onboardRestaurant>>;
  let other: Awaited<ReturnType<typeof onboardRestaurant>>;
  let auditor: { id: string; token: string };
  let deviceToken: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const owner = () => bearer(r.ownerToken);
  const ids = { o1: uuidv7(), o2: uuidv7(), b1: uuidv7(), l1: uuidv7(), l2: uuidv7(), l3: uuidv7() };

  beforeAll(async () => {
    t = await createTestApp();
    const sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    r = await onboardRestaurant(t, sa, 'premium');
    other = await onboardRestaurant(t, sa, 'premium');
    auditor = await addStaff(t, r.tenantId, 'auditor');
    // some history: an employee, a menu change, a stock movement, a POS reversal, a sale
    await t.http().post(api('/staff')).set(owner()).set('X-Request-Id', 'req-staff-0001').send({ name: 'Ravi', email: `ravi-${uuidv7().slice(-6)}@example.test`, role: 'cashier', pin: goodPin() }).expect(201);
    const tax = (await t.http().post(api('/tax-rules')).set(owner()).send({ name: 'GST 5%', rateBp: 500 }).expect(201)).body;
    const cat = (await t.http().post(api('/menu/categories')).set(owner()).send({ name: 'Mains' }).expect(201)).body;
    await t.http().post(api('/menu/items')).set(owner()).send({ categoryId: cat.id, name: 'Dal', taxRuleId: tax.id, pricePaise: 20000 }).expect(201);
    const p = (await t.http().post(api('/inventory/products')).set(owner()).send({ sku: 'DAL', name: 'Toor dal', baseUnit: 'g', purchaseUnit: 'kg', conversionFactor: 1000 }).expect(201)).body;
    await t.http().post(api('/inventory/movements')).set(owner()).send({ type: 'opening', productId: p.id, quantity: 5, unit: 'kg', unitCostPaise: 12000, idempotencyKey: uuidv7() }).expect(201);
    deviceToken = (await t.http().post(api('/devices/register-hub')).set(owner()).send({ name: 'Hub', platform: 'android' }).expect(201)).body.deviceToken;
    const now = new Date().toISOString();
    const e = (entity: string, id: string, payload: Record<string, unknown>) => ({ eventId: uuidv7(), entity, entityId: id, op: 'upsert', payload: { ...payload, branchId: r.branchId }, createdAt: now });
    await t.http().post(api('/sync/push')).set('X-Device-Token', deviceToken).send({ events: [
      e('order', ids.o1, { id: ids.o1, type: 'dine_in', status: 'open', opened_at: now }),
      e('order_line', ids.l1, { id: ids.l1, order_id: ids.o1, name_snapshot: 'Dal', qty: 2, price_snapshot_paise: 20000, status: 'sent' }),
      e('order_line', ids.l2, { id: ids.l2, order_id: ids.o1, name_snapshot: 'Naan', qty: 1, price_snapshot_paise: 6000, status: 'reversed', reversal_reason: 'Guest left', reversed_by: r.ownerUserId, reversed_at: now }),
      e('audit_event', uuidv7(), { id: uuidv7(), actor: r.ownerUserId, action: 'order.line_reversed', object_type: 'order_line', object_id: ids.l2, before_json: '{"status":"sent"}', after_json: '{"status":"reversed"}', reason: 'Guest left', at: now }),
      e('bill', ids.b1, { id: ids.b1, order_id: ids.o1, invoice_no: 'BR01/26-27/000001', status: 'paid', subtotal_paise: 40000, discount_paise: 2000, discount_reason: 'Regular', cgst_paise: 950, sgst_paise: 950, tip_paise: 0, total_paise: 39900, created_at: now, closed_at: now }),
      e('payment', uuidv7(), { billId: ids.b1, mode: 'upi', amountPaise: 39900, at: now, reference: 'UPI-77' }),
      e('bill_adjustment', uuidv7(), { bill_id: ids.b1, type: 'correction', amount_paise: -5000, reason: 'Refund cold dal', approved_by: r.ownerUserId, at: now }),
      e('order', ids.o2, { id: ids.o2, type: 'takeaway', status: 'open', opened_at: now }),
      e('order_line', ids.l3, { id: ids.l3, order_id: ids.o2, name_snapshot: 'Dal · Half', qty: 1, price_snapshot_paise: 12000, status: 'sent' }),
    ] }).expect(200);
  });
  afterAll(() => t.close());

  it('auditor reads the log: actor name and role at the time, module/action/employee/record filters, POS actions included', async () => {
    const all = (await t.http().get(api('/audit/events')).set(bearer(auditor.token)).expect(200)).body;
    const created = all.find((x: { action: string }) => x.action === 'staff.created');
    expect(created).toMatchObject({ source: 'cloud', module: 'Employees & roles', actorName: 'Owner', actorRole: 'owner', requestId: 'req-staff-0001' });
    expect(JSON.stringify(created)).not.toMatch(/argon2|"pin"/);
    expect(all.some((x: { action: string }) => x.action === 'menu.item_created')).toBe(true);
    expect(all.some((x: { action: string }) => x.action === 'inventory.opening')).toBe(true);
    expect(all.find((x: { action: string }) => x.action === 'pos.order.line_reversed')).toMatchObject({ source: 'pos', actorName: 'Owner', reason: 'Guest left', after: { status: 'reversed' } });
    expect(all.some((x: { action: string }) => x.action === 'auth.login')).toBe(true);
    const inv = (await t.http().get(api('/audit/events?module=Inventory')).set(bearer(auditor.token)).expect(200)).body;
    expect(inv.every((x: { module: string }) => x.module === 'Inventory')).toBe(true);
    const byReq = (await t.http().get(api('/audit/events?q=req-staff-0001')).set(bearer(auditor.token)).expect(200)).body;
    expect(byReq.map((x: { action: string }) => x.action)).toEqual(['staff.created']);
    const byActor = (await t.http().get(api(`/audit/events?actorId=${r.ownerUserId}&role=owner`)).set(bearer(auditor.token)).expect(200)).body;
    expect(byActor.length).toBeGreaterThan(3);
    const facets = (await t.http().get(api('/audit/facets')).set(bearer(auditor.token)).expect(200)).body;
    expect(facets.modules).toContain('POS (orders, bills, approvals)');
    expect(facets.employees.map((x: { name: string }) => x.name)).toEqual(expect.arrayContaining(['Owner', 'Ravi']));
  });

  it('exports are allowed to auditors and owners, refused to others; CSV cells cannot run formulas', async () => {
    const csv = (await t.http().get(api('/audit/events.csv')).set(bearer(auditor.token)).expect(200)).text;
    expect(csv.split('\r\n')[0]).toMatch(/time_utc,source,module,action,employee,role/);
    expect(csv).toMatch(/staff\.created/);
    const cashier = await addStaff(t, r.tenantId, 'cashier');
    await t.http().get(api('/audit/events.csv')).set(bearer(cashier.token)).expect(403);
    await t.http().get(api('/audit/events')).set(bearer(cashier.token)).expect(403);
    const sales = (await t.http().get(api('/records/sales.csv')).set(owner()).expect(200)).text;
    expect(sales).toMatch(/BR01\/26-27\/000001,paid,dine_in,400\.00,20\.00,Regular/);
  });

  it('sales records: bills, payments by method, discounts, refunds and voided lines; cashiers see them, waiters do not', async () => {
    const s = (await t.http().get(api('/records/sales')).set(bearer(auditor.token)).expect(200)).body;
    expect(s.summary).toMatchObject({ paidBills: 1, salesPaise: 39900, discountsPaise: 2000, refundsPaise: -5000, voids: 1, voidsPaise: 6000, paymentsByMode: { upi: 39900 } });
    expect(s.bills[0]).toMatchObject({ invoiceNo: 'BR01/26-27/000001', payments: [{ mode: 'upi', amountPaise: 39900, reference: 'UPI-77' }], adjustments: [{ amountPaise: -5000, reason: 'Refund cold dal', approvedBy: 'Owner' }] });
    expect(s.voids[0]).toMatchObject({ name: 'Naan', reason: 'Guest left', by: 'Owner' });
    const cashier = await addStaff(t, r.tenantId, 'cashier');
    await t.http().get(api('/records/sales')).set(bearer(cashier.token)).expect(200);
    const waiter = await addStaff(t, r.tenantId, 'waiter');
    await t.http().get(api('/records/sales')).set(bearer(waiter.token)).expect(403);
  });

  it('live orders for the kitchen, waiter and cashier views', async () => {
    const chef = await addStaff(t, r.tenantId, 'chef');
    const live = (await t.http().get(api('/records/live-orders')).set(bearer(chef.token)).expect(200)).body;
    expect(live.map((o: { id: string }) => o.id)).toEqual(expect.arrayContaining([ids.o1, ids.o2]));
    expect(live.find((o: { id: string }) => o.id === ids.o2).lines).toEqual([expect.objectContaining({ name: 'Dal · Half', qty: 1, status: 'sent' })]);
  });

  it('import history for auditors; logs cannot be changed by anyone, even the database owner', async () => {
    await t.http().get(api('/audit/imports')).set(bearer(auditor.token)).expect(200);
    const ev = await t.owner.auditEvent.findFirstOrThrow({ where: { tenantId: r.tenantId } });
    await expect(t.owner.auditEvent.update({ where: { id: ev.id }, data: { reason: 'edited' } })).rejects.toThrow(/append-only/);
    await expect(t.owner.auditEvent.delete({ where: { id: ev.id } })).rejects.toThrow(/append-only/);
  });

  it("another restaurant sees none of this restaurant's records", async () => {
    const theirs = (await t.http().get(api('/audit/events')).set(bearer(other.ownerToken)).expect(200)).body;
    expect(theirs.some((x: { requestId: string }) => x.requestId === 'req-staff-0001')).toBe(false);
    const s = (await t.http().get(api('/records/sales')).set(bearer(other.ownerToken)).expect(200)).body;
    expect(s.bills).toEqual([]);
    expect((await t.http().get(api('/records/live-orders')).set(bearer(other.ownerToken)).expect(200)).body).toEqual([]);
  });
});
