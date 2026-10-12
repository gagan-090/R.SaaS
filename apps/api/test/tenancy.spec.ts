/**
 * M1 — tenancy. Proves Postgres RLS isolates tenants for the runtime role, that audit_events is append-only,
 * that paid bills cannot be modified, and that tenant A cannot read tenant B through any endpoint.
 */
import { PrismaClient } from '@prisma/client';
import { uuidv7 } from '../src/common/uuid';
import { api, createAdmin, createTestApp, fillParams, listRoutes, loginAdmin, onboardRestaurant, TestApp } from './helpers';

describe('tenancy & RLS', () => {
  let t: TestApp;
  let appDb: PrismaClient; // the least-privilege runtime role, exactly as the API connects
  let A: Awaited<ReturnType<typeof onboardRestaurant>>;
  let B: Awaited<ReturnType<typeof onboardRestaurant>>;
  const bIds: string[] = [];

  beforeAll(async () => {
    t = await createTestApp();
    appDb = new PrismaClient({ datasources: { db: { url: process.env.DATABASE_URL } } });
    const sa = await createAdmin(t, ['Super Admin']);
    const { accessToken } = await loginAdmin(t, sa);
    A = await onboardRestaurant(t, accessToken);
    B = await onboardRestaurant(t, accessToken);
    for (const R of [A, B]) {
      const auth = { Authorization: `Bearer ${R.ownerToken}` };
      const floor = (await t.http().post(api('/floors')).set(auth).send({ branchId: R.branchId, name: 'Ground' }).expect(201)).body;
      const table = (await t.http().post(api('/tables')).set(auth).send({ floorId: floor.id, name: 'T1' }).expect(201)).body;
      const tax = (await t.http().post(api('/tax-rules')).set(auth).send({ name: 'GST 5%', rateBp: 500 }).expect(201)).body;
      const cat = (await t.http().post(api('/menu/categories')).set(auth).send({ name: 'Mains' }).expect(201)).body;
      const item = (await t.http().post(api('/menu/items')).set(auth).send({ categoryId: cat.id, name: 'Dal', pricePaise: 20000, taxRuleId: tax.id }).expect(201)).body;
      if (R === B) bIds.push(B.tenantId, B.branchId, B.ownerUserId, floor.id, table.id, tax.id, cat.id, item.id);
    }
  });

  afterAll(async () => {
    await appDb.$disconnect();
    await t.close();
  });

  const asTenant = <T>(tenantId: string, fn: (tx: PrismaClient) => Promise<T>) =>
    appDb.$transaction(async (tx) => {
      await tx.$queryRaw`SELECT set_config('app.tenant_id', ${tenantId}, true)`;
      return fn(tx as unknown as PrismaClient);
    });

  it('runtime role sees nothing without a tenant context', async () => {
    expect(await appDb.restaurantTenant.count({ where: { id: { in: [A.tenantId, B.tenantId] } } })).toBe(0);
    expect(await appDb.floor.count({ where: { tenantId: { in: [A.tenantId, B.tenantId] } } })).toBe(0);
    expect(await appDb.user.count({ where: { tenantId: { in: [A.tenantId, B.tenantId] } } })).toBe(0);
  });

  it('tenant A context returns 0 rows of tenant B on every tenant table', async () => {
    const counts = await asTenant(A.tenantId, async (tx) => ({
      tenants: await tx.restaurantTenant.count({ where: { id: B.tenantId } }),
      ownTenant: await tx.restaurantTenant.count({ where: { id: A.tenantId } }),
      branches: await tx.branch.count({ where: { tenantId: B.tenantId } }),
      users: await tx.user.count({ where: { tenantId: B.tenantId } }),
      roles: await tx.userRoleAssignment.count({ where: { tenantId: B.tenantId } }),
      licenses: await tx.license.count({ where: { tenantId: B.tenantId } }),
      floors: await tx.floor.count({ where: { tenantId: B.tenantId } }),
      tables: await tx.table.count({ where: { tenantId: B.tenantId } }),
      tax: await tx.taxRule.count({ where: { tenantId: B.tenantId } }),
      cats: await tx.menuCategory.count({ where: { tenantId: B.tenantId } }),
      items: await tx.menuItem.count({ where: { tenantId: B.tenantId } }),
      audit: await tx.auditEvent.count({ where: { tenantId: B.tenantId } }),
      ownFloors: await tx.floor.count({ where: { tenantId: A.tenantId } }),
    }));
    expect(counts).toEqual({
      tenants: 0, ownTenant: 1, branches: 0, users: 0, roles: 0, licenses: 0, floors: 0, tables: 0, tax: 0, cats: 0, items: 0, audit: 0, ownFloors: 1,
    });
  });

  it('tenant A cannot write a row tagged with tenant B (WITH CHECK)', async () => {
    await expect(asTenant(A.tenantId, (tx) => tx.taxRule.create({ data: { tenantId: B.tenantId, name: 'x', rateBp: 0 } }))).rejects.toThrow(/row-level security/);
  });

  it('runtime role cannot UPDATE or DELETE audit_events (append-only)', async () => {
    const ev = await t.owner.auditEvent.findFirstOrThrow({ where: { tenantId: A.tenantId } });
    await expect(asTenant(A.tenantId, (tx) => tx.auditEvent.update({ where: { id: ev.id }, data: { action: 'tampered' } }))).rejects.toThrow(/permission denied/);
    await expect(asTenant(A.tenantId, (tx) => tx.auditEvent.delete({ where: { id: ev.id } }))).rejects.toThrow(/permission denied/);
    // even the owner role is stopped by the trigger
    await expect(t.owner.auditEvent.update({ where: { id: ev.id }, data: { action: 'tampered' } })).rejects.toThrow(/append-only/);
  });

  it('a paid bill cannot be modified; corrections go to bill_adjustments', async () => {
    const id = uuidv7();
    await asTenant(A.tenantId, (tx) =>
      tx.bill.create({
        data: {
          id, tenantId: A.tenantId, branchId: A.branchId, orderId: uuidv7(), invoiceNo: `BR01/26-27/${Date.now() % 1e6}`,
          subtotalPaise: 10000, discountPaise: 0, cgstPaise: 250, sgstPaise: 250, tipPaise: 0, roundOffPaise: 0, totalPaise: 10500,
          status: 'paid', closedAt: new Date(), createdAt: new Date(),
        },
      }),
    );
    await expect(asTenant(A.tenantId, (tx) => tx.bill.update({ where: { id }, data: { totalPaise: 1 } }))).rejects.toThrow(/cannot be modified/);
    await asTenant(A.tenantId, (tx) =>
      tx.billAdjustment.create({ data: { id: uuidv7(), tenantId: A.tenantId, branchId: A.branchId, billId: id, type: 'correction', amountPaise: -500, reason: 'test', actor: A.ownerUserId, at: new Date() } }),
    );
  });

  it('tenant A cannot read tenant B through any endpoint', async () => {
    const auth = { Authorization: `Bearer ${A.ownerToken}` };
    const routes = listRoutes(t.app).filter((r) => r.method === 'GET' && !r.isPublic);
    expect(routes.length).toBeGreaterThan(5);
    for (const r of routes) {
      if (r.path.includes(':')) {
        for (const id of bIds) {
          const res = await t.http().get(fillParams(r.path, id)).set(auth);
          expect({ route: r.path, id, status: res.status < 300 ? 'leak' : 'ok' }).toEqual({ route: r.path, id, status: 'ok' });
        }
      } else {
        const res = await t.http().get(r.path).set(auth);
        const body = JSON.stringify(res.body ?? '');
        for (const id of bIds) expect({ route: r.path, leaked: body.includes(id) }).toEqual({ route: r.path, leaked: false });
      }
    }
    // and writes aimed at B's objects miss
    await t.http().patch(api(`/tables/${bIds[4]}`)).set(auth).send({ seats: 9 }).expect(404);
    await t.http().patch(api(`/menu/items/${bIds[7]}`)).set(auth).send({ pricePaise: 1 }).expect(404);
  });
});
