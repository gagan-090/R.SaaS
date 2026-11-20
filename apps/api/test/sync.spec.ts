/** M5 cloud side — /sync/push dedupes by event id; /sync/pull returns config by cursor with the signed license. */
import { uuidv7 } from '../src/common/uuid';
import { verifyLicense } from '../src/licensing/license-token';
import { loadEnv } from '../src/config/env';
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant, defaultFloor } from './helpers';

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

  it('a branch keeps its first main device: a second registration gets hub_exists unless it deliberately replaces it', async () => {
    const again = await t.http().post(api('/devices/register-hub')).set(bearer(R.ownerToken)).send({ name: 'Owner phone', platform: 'android' }).expect(409);
    expect(again.body).toMatchObject({ code: 'hub_exists', hubName: 'Cashier PC' });
    // the first main device keeps working
    await t.http().get(api('/sync/pull')).set('X-Device-Token', device).expect(200);
    // staff emails go to the hub so new devices can join it with email + PIN
    const pull = (await t.http().get(api('/sync/pull')).set('X-Device-Token', device).expect(200)).body;
    expect(pull.users.length).toBeGreaterThan(0);
    for (const u of pull.users) expect(u.email).toEqual(expect.stringContaining('@'));
  });

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
    const floor = await defaultFloor(t, R.ownerToken); // every restaurant starts with one floor
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

  it('a replacement main device learns the last invoice number used, so it never starts again at 000001', async () => {
    const bill = (no: string, op = 'create') => ({ ...ev('bill'), op, payload: { branchId: R.branchId, invoice_no: no, status: 'billed' } });
    await t.http().post(api('/sync/push')).set('X-Device-Token', device)
      .send({ events: [bill('BR01/26-27/000007'), bill('BR01/26-27/000012'), bill('BR01/26-27/000012', 'update'), bill('BR01/25-26/000300')] }).expect(200);
    const reg = (await t.http().post(api('/devices/register-hub')).set(bearer(R.ownerToken))
      .send({ name: 'Owner phone', platform: 'android', replace: true }).expect(201)).body;
    device = reg.deviceToken;
    const pull = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', device).expect(200)).body;
    expect(pull.invoiceCounters).toEqual(expect.arrayContaining([
      { branchCode: 'BR01', fy: '26-27', lastNumber: 12 },
      { branchCode: 'BR01', fy: '25-26', lastNumber: 300 },
    ]));
    expect(pull.invoiceCounters).toHaveLength(2);
  });

  it('a new main device gets the branch bill history (orders, bills, payments) page by page, without audit rows', async () => {
    const first = (await t.http().post(api('/devices/register-hub')).set(bearer(R.ownerToken))
      .send({ name: 'Old phone', platform: 'android', replace: true }).expect(201)).body.deviceToken;
    const batch = [ev('order'), ev('bill'), ev('payment'), ev('audit_event')];
    await t.http().post(api('/sync/push')).set('X-Device-Token', first).send({ events: batch }).expect(200);
    const next = (await t.http().post(api('/devices/register-hub')).set(bearer(R.ownerToken))
      .send({ name: 'New phone', platform: 'android', replace: true }).expect(201)).body.deviceToken;
    const all: { eventId: string; entity: string }[] = [];
    let after: string | undefined;
    for (let i = 0; i < 50; i++) {
      const q = after ? `?after=${encodeURIComponent(after)}` : '';
      const page = (await t.http().get(api(`/sync/history${q}`)).set('X-Device-Token', next).expect(200)).body;
      all.push(...page.events);
      after = page.cursor ?? after;
      if (!page.more) break;
    }
    const ids = all.map((e) => e.eventId);
    expect(ids).toEqual(expect.arrayContaining(batch.slice(0, 3).map((e) => e.eventId)));
    expect(ids).not.toContain(batch[3].eventId);
    expect(new Set(ids).size).toBe(ids.length);
    // nothing new after the last cursor
    const tail = (await t.http().get(api(`/sync/history?after=${encodeURIComponent(after!)}`)).set('X-Device-Token', next).expect(200)).body;
    expect(tail).toMatchObject({ events: [], more: false, cursor: after });
    await t.http().get(api('/sync/history?after=bad')).set('X-Device-Token', next).expect(400);
    device = next;
  });

  it('unknown or missing device tokens are refused', async () => {
    await t.http().post(api('/sync/push')).send({ events: [] }).expect(401);
    await t.http().get(api('/sync/pull')).set('X-Device-Token', 'nope').expect(401);
  });
});
