/** M5 cloud side — /sync/push dedupes by event id; /sync/pull returns config by cursor with the signed license. */
import { uuidv7 } from '../src/common/uuid';
import { verifyLicense } from '../src/licensing/license-token';
import { loadEnv } from '../src/config/env';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

describe('sync', () => {
  let t: TestApp;
  let R: Awaited<ReturnType<typeof onboardRestaurant>>;
  let device: string;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  beforeAll(async () => {
    t = await createTestApp();
    const sa = await createAdmin(t, ['Super Admin']);
    R = await onboardRestaurant(t, (await loginAdmin(t, sa)).accessToken);
    const reg = (await t.http().post(api('/devices/register-hub')).set(bearer(R.ownerToken)).send({ name: 'Cashier PC', platform: 'windows' }).expect(201)).body;
    expect(reg).toMatchObject({ branchId: R.branchId, branchCode: 'BR01', licensePublicKey: loadEnv().LICENSE_PUBLIC_KEY });
    device = reg.deviceToken;
  });
  afterAll(() => t.close());

  const ev = (entity = 'order') => ({ eventId: uuidv7(), entity, entityId: uuidv7(), op: 'create', payload: { branchId: R.branchId }, createdAt: new Date().toISOString() });

  it('the same outbox batch pushed twice is stored once', async () => {
    const batch = [ev(), ev('order_line'), ev('payment')];
    const r1 = await t.http().post(api('/sync/push')).set('X-Device-Token', device).send({ events: batch }).expect(200);
    expect(r1.body.results.map((r: { result: string }) => r.result)).toEqual(['accepted', 'accepted', 'accepted']);
    const r2 = await t.http().post(api('/sync/push')).set('X-Device-Token', device).send({ events: batch }).expect(200);
    expect(r2.body.results.map((r: { result: string }) => r.result)).toEqual(['duplicate', 'duplicate', 'duplicate']);
    expect(await t.owner.syncEvent.count({ where: { eventId: { in: batch.map((e) => e.eventId) } } })).toBe(3);
  });

  it('rejects events the hub does not own or for another branch into sync_conflicts', async () => {
    const bad = ev('menu_item');
    const other = { ...ev(), payload: { branchId: uuidv7() } };
    const r = await t.http().post(api('/sync/push')).set('X-Device-Token', device).send({ events: [bad, other] }).expect(200);
    expect(r.body.results.map((x: { result: string }) => x.result)).toEqual(['rejected', 'rejected']);
    expect(await t.owner.syncConflict.count({ where: { eventId: { in: [bad.eventId, other.eventId] } } })).toBe(2);
    const again = await t.http().post(api('/sync/push')).set('X-Device-Token', device).send({ events: [bad] }).expect(200);
    expect(again.body.results[0].result).toBe('rejected');
    const st = await t.http().get(api('/sync/status')).set('X-Device-Token', device).expect(200);
    expect(st.body.openConflicts).toBe(2);
  });

  it('pull returns config since the cursor, with a verifiable license token', async () => {
    const auth = bearer(R.ownerToken);
    const floor = (await t.http().post(api('/floors')).set(auth).send({ branchId: R.branchId, name: 'Ground' }).expect(201)).body;
    await t.http().post(api('/tables')).set(auth).send({ floorId: floor.id, name: 'T1' }).expect(201);
    const p1 = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', device).expect(200)).body;
    expect(p1.floors).toHaveLength(1);
    expect(p1.tables).toHaveLength(1);
    expect(p1.users.some((u: { roles: { role: string }[] }) => u.roles.some((r) => r.role === 'owner'))).toBe(true);
    expect(verifyLicense(p1.licenseToken, loadEnv().LICENSE_PUBLIC_KEY)?.tid).toBe(R.tenantId);
    const p2 = (await t.http().get(api(`/sync/pull?since=${p1.cursor}`)).set('X-Device-Token', device).expect(200)).body;
    expect(p2.floors).toHaveLength(0);
    expect(p2.tables).toHaveLength(0);
    await t.http().post(api('/tables')).set(auth).send({ floorId: floor.id, name: 'T2' }).expect(201);
    const p3 = (await t.http().get(api(`/sync/pull?since=${p1.cursor}`)).set('X-Device-Token', device).expect(200)).body;
    expect(p3.tables.map((x: { name: string }) => x.name)).toEqual(['T2']);
  });

  it('unknown or missing device tokens are refused', async () => {
    await t.http().post(api('/sync/push')).send({ events: [] }).expect(401);
    await t.http().get(api('/sync/pull')).set('X-Device-Token', 'nope').expect(401);
  });
});
