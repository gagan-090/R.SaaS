/** Cloud relay: a device on another network reaches its branch's main device through the cloud. */
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

describe('relay', () => {
  let t: TestApp;
  let R: Awaited<ReturnType<typeof onboardRestaurant>>;
  let hub: string;
  const base = () => `/relay/b/${R.branchId}/hub/v1`;

  beforeAll(async () => {
    t = await createTestApp();
    const sa = await createAdmin(t, ['Super Admin']);
    R = await onboardRestaurant(t, (await loginAdmin(t, sa)).accessToken);
    hub = (await t.http().post(api('/devices/register-hub')).set({ Authorization: `Bearer ${R.ownerToken}` }).send({ name: 'Cashier PC', platform: 'windows' }).expect(201)).body.deviceToken;
  });
  afterAll(() => t.close());

  /** One hub long-poll that answers each request with [answer]. */
  const serveOnce = async (answer: (r: { id: string; method: string; path: string; headers: Record<string, string>; body?: string }) => object) => {
    const poll = await t.http().post(api('/relay/hub/poll')).set('X-Device-Token', hub).expect(200);
    const responses = poll.body.requests.map((r: Parameters<typeof answer>[0]) => ({ id: r.id, ...answer(r) }));
    await t.http().post(api('/relay/hub/reply')).set('X-Device-Token', hub).send({ responses }).expect(200);
    return poll.body.requests as Parameters<typeof answer>[0][];
  };

  it('says the main device is offline until it polls', async () => {
    const r = await t.http().get(api(`${base()}/state`)).set('X-Device-Token', 'dev-token').expect(503);
    expect(r.body.code).toBe('hub_offline');
    expect((await t.http().get(api(`/relay/b/${R.branchId}/status`)).expect(200)).body).toEqual({ hubOnline: false });
  });

  it('only a main device can serve the relay', async () => {
    await t.http().post(api('/relay/hub/poll')).set('X-Device-Token', 'nope').expect(401);
  });

  it('forwards a request with only the allowed headers and returns the hub answer', async () => {
    // the hub is waiting before the device calls
    const served = serveOnce((r) => ({ status: 201, headers: { 'content-type': 'application/json', 'set-cookie': 'x' }, bodyB64: Buffer.from(JSON.stringify({ echo: r.body })).toString('base64') }));
    await new Promise((res) => setTimeout(res, 100));
    const res = await t.http().post(api(`${base()}/orders?x=1`)).set({ 'X-Device-Token': 'dev-token', Authorization: 'Bearer s', 'Idempotency-Key': 'k1', Cookie: 'c=1' }).send({ type: 'dine_in' }).expect(201);
    expect(res.body).toEqual({ echo: JSON.stringify({ type: 'dine_in' }) });
    expect(res.headers['set-cookie']).toBeUndefined();
    const [req] = await served;
    expect(req).toMatchObject({ method: 'POST', path: 'orders?x=1' });
    expect(req.headers).toEqual({ 'x-device-token': 'dev-token', authorization: 'Bearer s', 'idempotency-key': 'k1', 'content-type': 'application/json' });
  });

  it('a request queued before the hub polls is delivered on its next poll', async () => {
    await t.http().post(api('/relay/hub/reply')).set('X-Device-Token', hub).send({}).expect(200);
    const call = t.http().get(api(`${base()}/bills/b1/print`)).set('X-Device-Token', 'dev-token').then((r) => r);
    await new Promise((res) => setTimeout(res, 100));
    await serveOnce(() => ({ status: 200, headers: { 'content-type': 'application/pdf', 'x-print-status': 'pdf' }, bodyB64: Buffer.from('%PDF').toString('base64') }));
    const r = await call;
    expect(r.status).toBe(200);
    expect(r.headers['content-type']).toBe('application/pdf');
    expect(r.headers['x-print-status']).toBe('pdf');
  });

  it('never relays joining with email + PIN or the WebSocket', async () => {
    expect((await t.http().post(api(`${base()}/pairing/staff-claim`)).send({ email: 'a@b.c', pin: '1234' }).expect(403)).body.code).toBe('not_relayed');
    await t.http().get(api(`${base()}/events`)).expect(403);
    // encoded or dotted spellings of the same path are refused before the check
    for (const p of ['pairing%2Fstaff-claim', 'pairing/./staff-claim', 'pairing//staff-claim', 'x/../pairing/staff-claim', 'pairing/staff-claim%00', 'Pairing/Staff-Claim', 'EVENTS']) {
      await t.http().post(api(`${base()}/${p}`)).send({ email: 'a@b.c', pin: '1234' }).expect((r) => expect([400, 403, 404]).toContain(r.status));
    }
  });

  it('live events: only for a device the hub knows, in order, from the current position', async () => {
    const check = serveOnce((r) => ({ status: r.headers['x-device-token'] === 'good' ? 200 : 401 }));
    await new Promise((res) => setTimeout(res, 100));
    const start = (await t.http().get(api(`/relay/b/${R.branchId}/events`)).set('X-Device-Token', 'good').expect(200)).body;
    await check;
    expect(start).toMatchObject({ events: [], reset: false });
    const wait = t.http().get(api(`/relay/b/${R.branchId}/events?after=${start.seq}`)).set('X-Device-Token', 'good').then((r) => r);
    await new Promise((res) => setTimeout(res, 100));
    await t.http().post(api('/relay/hub/reply')).set('X-Device-Token', hub).send({ events: [{ type: 'order.updated', n: 1 }, { type: 'order.updated', n: 2 }] }).expect(200);
    const got = (await wait).body;
    expect(got.events.map((e: { n: number }) => e.n)).toEqual([1, 2]);
    expect(got.seq).toBe(start.seq + 2);

    const bad = serveOnce(() => ({ status: 401 }));
    await new Promise((res) => setTimeout(res, 100));
    await t.http().get(api(`/relay/b/${R.branchId}/events`)).set('X-Device-Token', 'bad').expect(401);
    await bad;
  });
});
