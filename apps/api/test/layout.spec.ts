/** Visual floor layout: save / reload, unique names, optimistic lock, open orders, overlap warnings, live states. */
import { uuidv7 } from '../src/common/uuid';
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

describe('floor layout editor', () => {
  let t: TestApp;
  let r: Awaited<ReturnType<typeof onboardRestaurant>>;
  let std: Awaited<ReturnType<typeof onboardRestaurant>>;
  let floor: { id: string };
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const auth = () => bearer(r.ownerToken);
  const tbl = (name: string, x: number, y: number, extra: Record<string, unknown> = {}) => ({ name, seats: 4, shape: 'square', x, y, width: 80, height: 80, rotation: 0, ...extra });

  beforeAll(async () => {
    t = await createTestApp();
    const sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    r = await onboardRestaurant(t, sa, 'premium');
    std = await onboardRestaurant(t, sa, 'standard');
    floor = (await t.http().post(api('/floors')).set(auth()).send({ branchId: r.branchId, name: 'Ground' }).expect(201)).body;
  });
  afterAll(() => t.close());

  it('saves shapes, positions, sizes, rotation and chairs; they persist after reload; the hub pulls them', async () => {
    const reg = (await t.http().post(api('/devices/register-hub')).set(auth()).send({ name: 'Hub', platform: 'android' }).expect(201)).body;
    const l0 = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    expect(l0.floor).toMatchObject({ width: 1200, height: 800, version: 1 });
    const chairs = [{ x: -60, y: 0, rotation: 90 }, { x: 60, y: 0, rotation: 270 }];
    const saved = (await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({
      version: 1, width: 1600, height: 900,
      tables: [
        tbl('1', 150, 150, { shape: 'round', seats: 2, chairs }),
        tbl('2', 400, 150, { shape: 'rect', seats: 6, width: 160, height: 80, rotation: 90 }),
        tbl('Patio-A', 700, 400, { seats: 4 }),
      ],
    }).expect(200)).body;
    expect(saved.floor).toMatchObject({ width: 1600, height: 900, version: 2 });
    const again = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    const one = again.tables.find((x: { name: string }) => x.name === '1');
    expect(one).toMatchObject({ shape: 'round', seats: 2, x: 150, y: 150, chairs, live: 'available' });
    expect(again.tables.find((x: { name: string }) => x.name === '2')).toMatchObject({ shape: 'rect', width: 160, rotation: 90 });
    const pull = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', reg.deviceToken).expect(200)).body;
    expect(pull.tables.find((x: { name: string }) => x.name === '2')).toMatchObject({ shape: 'rect', posX: 400, rotation: 90 });
    const audit = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'floor.layout_saved', objectId: floor.id } });
    expect(audit.after).toMatchObject({ width: 1600 });
  });

  it('a stale editor cannot overwrite a newer save; duplicate names are refused; overlaps only warn', async () => {
    const cur = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    const tables = cur.tables.map(({ live: _l, floorId: _f, status: _s, ...x }: Record<string, unknown>) => x);
    expect((await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: 1, width: 1600, height: 900, tables }).expect(409)).body.code).toBe('layout_changed');
    const dup = await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: cur.floor.version, width: 1600, height: 900, tables: [...tables, tbl('patio-a', 900, 600)] }).expect(409);
    expect(dup.body.code).toBe('duplicate_table_name');
    // overlapping tables save, with a warning
    const ov = (await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: cur.floor.version, width: 1600, height: 900, tables: [...tables, tbl('3', 160, 160)] }).expect(200)).body;
    expect(ov.warnings).toEqual([{ a: '1', b: '3' }]);
    // swapping two names in one save works
    const now = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    const swapped = now.tables.map(({ live: _l, floorId: _f, status: _s, ...x }: Record<string, unknown>) => ({ ...x, name: x.name === '1' ? '3' : x.name === '3' ? '1' : x.name }));
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: now.floor.version, width: 1600, height: 900, tables: swapped }).expect(200);
  });

  it('a table with an open order cannot be removed; past orders keep their table; the live view shows occupied', async () => {
    const cur = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    const target = cur.tables.find((x: { name: string }) => x.name === 'Patio-A');
    const reg = (await t.http().post(api('/devices/register-hub')).set(auth()).send({ name: 'Hub 2', platform: 'android' }).expect(201)).body;
    const orderId = uuidv7();
    const ev = (status: string) => ({ eventId: uuidv7(), entity: 'order', entityId: orderId, op: 'update', payload: { id: orderId, type: 'dine_in', table_id: target.id, status, branchId: r.branchId }, createdAt: new Date().toISOString() });
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events: [ev('open')] }).expect(200);
    const live = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    expect(live.tables.find((x: { id: string }) => x.id === target.id).live).toBe('occupied');
    const without = cur.tables.filter((x: { id: string }) => x.id !== target.id).map(({ live: _l, floorId: _f, status: _s, ...x }: Record<string, unknown>) => x);
    const refused = await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: cur.floor.version, width: 1600, height: 900, tables: without }).expect(409);
    expect(refused.body.code).toBe('table_has_open_order');
    await t.http().delete(api(`/tables/${target.id}`)).set(auth()).expect(409);
    await t.http().post(api(`/tables/${target.id}/status`)).set(auth()).send({ status: 'unavailable' }).expect(409);
    // order paid → the table can go; it is retired, not deleted, and its name is free again
    await t.http().post(api('/sync/push')).set('X-Device-Token', reg.deviceToken).send({ events: [ev('paid')] }).expect(200);
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: cur.floor.version, width: 1600, height: 900, tables: without }).expect(200);
    const retired = await t.owner.table.findUniqueOrThrow({ where: { id: target.id } });
    expect(retired.deleted).toBe(true);
    expect(retired.name).toMatch(/^Patio-A \(removed /);
    const next = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(auth()).expect(200)).body;
    const back = next.tables.map(({ live: _l, floorId: _f, status: _s, ...x }: Record<string, unknown>) => x);
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(auth()).send({ version: next.floor.version, width: 1600, height: 900, tables: [...back, tbl('Patio-A', 700, 400)] }).expect(200);
  });

  it('staff mark tables reserved; waiters and auditors view the floor but cannot edit it; plan and tenant limits hold', async () => {
    const waiter = await addStaff(t, r.tenantId, 'waiter');
    const auditor = await addStaff(t, r.tenantId, 'auditor');
    const cur = (await t.http().get(api(`/floors/${floor.id}/layout`)).set(bearer(waiter.token)).expect(200)).body;
    const one = cur.tables[0];
    await t.http().post(api(`/tables/${one.id}/status`)).set(bearer(waiter.token)).send({ status: 'reserved' }).expect(200);
    expect((await t.http().get(api(`/floors/${floor.id}/layout`)).set(bearer(auditor.token)).expect(200)).body.tables.find((x: { id: string }) => x.id === one.id).live).toBe('reserved');
    const body = { version: cur.floor.version, width: 1600, height: 900, tables: [] };
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(bearer(waiter.token)).send(body).expect(403);
    await t.http().put(api(`/floors/${floor.id}/layout`)).set(bearer(auditor.token)).send(body).expect(403);
    await t.http().post(api(`/tables/${one.id}/status`)).set(bearer(auditor.token)).send({ status: 'available' }).expect(403);
    // another restaurant cannot see or edit this floor
    await t.http().get(api(`/floors/${floor.id}/layout`)).set(bearer(std.ownerToken)).expect(404);
    // a plan without the editor: viewing works, saving is refused even by a direct API call
    const sf = (await t.http().post(api('/floors')).set(bearer(std.ownerToken)).send({ branchId: std.branchId, name: 'Main' }).expect(201)).body;
    const sl = (await t.http().get(api(`/floors/${sf.id}/layout`)).set(bearer(std.ownerToken)).expect(200)).body;
    const r403 = await t.http().put(api(`/floors/${sf.id}/layout`)).set(bearer(std.ownerToken)).send({ version: sl.floor.version, width: 1200, height: 800, tables: [] }).expect(403);
    expect(r403.body.code).toBe('feature_not_in_plan');
  });

  it('tables added with the simple form get their own spot on the plan', async () => {
    const f = (await t.http().post(api('/floors')).set(auth()).send({ branchId: r.branchId, name: 'Roof' }).expect(201)).body;
    const a = (await t.http().post(api('/tables')).set(auth()).send({ floorId: f.id, name: 'R1', seats: 2 }).expect(201)).body;
    const b = (await t.http().post(api('/tables')).set(auth()).send({ floorId: f.id, name: 'R2', seats: 6 }).expect(201)).body;
    expect([a.posX, b.posX, a.shape, b.shape]).toEqual([120, 280, 'round', 'rect']);
    await t.http().post(api('/tables')).set(auth()).send({ floorId: f.id, name: 'R1' }).expect(409);
  });
});
