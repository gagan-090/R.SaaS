import { randomUUID } from 'crypto';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

describe('client review regression', () => {
 let t: TestApp;
 let admin: string;
 let r: Awaited<ReturnType<typeof onboardRestaurant>>;
 const headers = () => ({ Authorization: `Bearer ${r.ownerToken}` });
 beforeAll(async () => { t = await createTestApp(); admin = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken; r = await onboardRestaurant(t, admin, 'premium'); });
 afterAll(() => t.close());
 it('creates menu rows together and rejects duplicates without partial writes', async () => {
   const tax = await t.owner.taxRule.create({ data: { tenantId: r.tenantId, name: 'GST', rateBp: 500 } });
   const body = { categoryName: 'Quick mains', taxRuleId: tax.id, items: [{ name: 'Dal', pricePaise: 18000 }, { name: 'Rice', pricePaise: 12000 }] };
   await t.http().post(api('/menu/quick-create')).set(headers()).send(body).expect(201);
   await t.http().post(api('/menu/quick-create')).set(headers()).send(body).expect(409);
   expect(await t.owner.menuItem.count({ where: { tenantId: r.tenantId } })).toBe(2);
 });
 it('receives purchases atomically, deduplicates retries and allows a zero stock count', async () => {
   const p = (await t.http().post(api('/inventory/products')).set(headers()).send({ sku: 'CLIENT-RICE', name: 'Rice', baseUnit: 'kg', purchaseUnit: 'kg', conversionFactor: 1 }).expect(201)).body;
   const supplier = (await t.http().post(api('/inventory/suppliers')).set(headers()).send({ name: 'Review supplier' }).expect(201)).body;
   const body = { supplierId: supplier.id, reference: 'INV-1', idempotencyKey: randomUUID(), lines: [{ productId: p.id, quantity: 5, unit: 'kg', unitCostPaise: 8000 }] };
   await t.http().post(api('/inventory/purchases')).set(headers()).send(body).expect(201);
   const retry = await t.http().post(api('/inventory/purchases')).set(headers()).send(body).expect(201);
   expect(retry.body.duplicate).toBe(true);
   await t.http().post(api('/inventory/purchases')).set(headers()).send({ ...body, reference: 'INV-2', idempotencyKey: randomUUID(), lines: [...body.lines, { ...body.lines[0], productId: randomUUID() }] }).expect(404);
   const stock = await t.http().get(api(`/inventory/products/${p.id}`)).set(headers()).expect(200);
   expect(stock.body.stock).toBe(5);
   await t.http().post(api('/inventory/movements')).set(headers()).send({ type: 'count', productId: p.id, quantity: 0, unit: 'kg', reason: 'Physical stock empty', idempotencyKey: randomUUID() }).expect(201);
   expect((await t.http().get(api(`/inventory/products/${p.id}`)).set(headers())).body.stock).toBe(0);
 });
 it('stores floor backgrounds and rejects overlapping reservations', async () => {
   const floor = await t.owner.floor.create({ data: { tenantId: r.tenantId, branchId: r.branchId, name: 'Review floor' } });
   const table = await t.owner.table.create({ data: { tenantId: r.tenantId, branchId: r.branchId, floorId: floor.id, name: 'R1', seats: 4 } });
   const backgroundImage = 'data:image/jpeg;base64,/9j/2Q==';
   await t.http().put(api(`/floors/${floor.id}/layout`)).set(headers()).send({ version: 1, width: 1200, height: 800, backgroundImage, tables: [{ id: table.id, name: 'R1', seats: 4, shape: 'square', x: 100, y: 100, width: 80, height: 80 }] }).expect(200);
   expect((await t.http().get(api(`/floors/${floor.id}/layout`)).set(headers())).body.floor.backgroundImage).toBe(backgroundImage);
   const body = { guestName: 'Test guest', guests: 2, startsAt: new Date(Date.now()+3600000).toISOString(), endsAt: new Date(Date.now()+7200000).toISOString() };
   const reservation = (await t.http().post(api(`/tables/${table.id}/reservations`)).set(headers()).send(body).expect(201)).body;
   await t.http().post(api(`/tables/${table.id}/reservations`)).set(headers()).send(body).expect(409);
   await t.http().post(api(`/tables/${table.id}/reservations`)).set(headers()).send({ ...body, guests: 5 }).expect(409);
   expect((await t.http().get(api(`/floors/${floor.id}/layout`)).set(headers())).body.reservations).toHaveLength(1);
   await t.http().post(api(`/reservations/${reservation.id}/cancel`)).set(headers()).send({}).expect(201);
   expect((await t.http().get(api(`/floors/${floor.id}/layout`)).set(headers())).body.reservations).toHaveLength(0);
 });
 it('activates a registration with a password without sending another email', async () => {
   const email = `${randomUUID()}@example.test`;
   const reg = (await t.http().post(api('/restaurants')).set('Authorization', `Bearer ${admin}`).send({ ownerEmail: email, ownerName: 'Client owner', restaurantName: 'Client activation', planCode: 'premium' }).expect(201)).body;
   const password = `Test-${randomUUID()}`;
   await t.http().post(api(`/restaurants/registrations/${reg.registrationId}/activate`)).set('Authorization', `Bearer ${admin}`).send({ password }).expect(201);
   await t.http().post(api('/auth/login')).send({ email, password }).expect(200);
   await t.http().post(api(`/restaurants/registrations/${reg.registrationId}/activate`)).set('Authorization', `Bearer ${admin}`).send({ password }).expect(409);
 });
 it('shows all platform audit events without a category filter', async () => {
   const res = await t.http().get(api('/platform/audit')).set('Authorization', `Bearer ${admin}`).expect(200);
   expect(res.body.items.length).toBeGreaterThan(0);
 });
});
