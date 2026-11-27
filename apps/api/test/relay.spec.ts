/** Cloud relay: a device on another network reaches its branch's main device through the cloud. */
import { TestApp, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

type Req = { id: string; method: string; path: string; headers: Record<string, string>; body?: string };

describe('relay', () => {
  let t: TestApp;
  let R: Awaited<ReturnType<typeof onboardRestaurant>>;
  let hub: string;
  const base = () => `/relay/b/${R.branchId}/hub/v1`;
  const known = new Set(['dev-token', 'good']);

  beforeAll(async () => {
    t = await createTestApp();
    const sa = await createAdmin(t, ['Super Admin']);
    R = await onboardRestaurant(t, (await loginAdmin(t, sa)).accessToken);
    hub = (await t.http().post(api('/devices/register-hub')).set({ Authorization: `Bearer ${R.ownerToken}` }).send({ name: 'Cashier PC', platform: 'windows' }).expect(201)).body.deviceToken;
  });
  afterAll(() => t.close());

  /**
   * A fake main device: long-polls until [answer] has served one non-`whoami` request (or [polls] run out), answering
   * the relay's device checks like a real hub (known tokens only). Returns the requests it answered.
   */
  const serve = async (answer: (r: Req) => object, polls = 3) => {
    const served: Req[] = [];
    for (let i = 0; i < polls && !served.length; i++) {
      const poll = await t.http().post(api('/relay/hub/poll')).set('X-Device-Token', hub).expect(200);
      const responses = poll.body.requests.map((r: Req) => {
        if (r.path === 'whoami') return { id: r.id, status: known.has(r.headers['x-device-token']) ? 200 : 401 };
        served.push(r);
        return { id: r.id, ...answer(r) };
      });
      await t.http().post(api('/relay/hub/reply')).set('X-Device-Token', hub).send({ responses }).expect(200);
    }
    return served;
  };
  const tick = () => new Promise((res) => setTimeout(res, 100));

  it('says the main device is offline until it polls', async () => {
    const r = await t.http().get(api(`${base()}/state`)).set('X-Device-Token', 'dev-token').expect(503);
    expect(r.body.code).toBe('hub_offline');
    expect((await t.http().get(api(`/relay/b/${R.branchId}/status`)).expect(200)).body).toEqual({ hubOnline: false });
  });

  it('only a main device can serve the relay', async () => {
    await t.http().post(api('/relay/hub/poll')).set('X-Device-Token', 'nope').expect(401);
  });

  it('forwards a request with only the allowed headers and returns the hub answer', async () => {
    const served = serve((r) => ({ status: 201, headers: { 'content-type': 'application/json', 'set-cookie': 'x' }, bodyB64: Buffer.from(JSON.stringify({ echo: r.body })).toString('base64') }));
    await tick();
    const res = await t.http().post(api(`${base()}/orders?x=1`)).set({ 'X-Device-Token': 'dev-token', Authorization: 'Bearer s', 'Idempotency-Key': 'k1', Cookie: 'c=1' }).send({ type: 'dine_in' }).expect(201);
    expect(res.body).toEqual({ echo: JSON.stringify({ type: 'dine_in' }) });
    expect(res.headers['set-cookie']).toBeUndefined();
    const [req] = await served;
    expect(req).toMatchObject({ method: 'POST', path: 'orders?x=1' });
    expect(req.headers).toEqual({ 'x-device-token': 'dev-token', authorization: 'Bearer s', 'idempotency-key': 'k1', 'content-type': 'application/json' });
  });

  it('a device the main device does not know gets nothing through (no anonymous access to the hub)', async () => {
    const served = serve(() => ({ status: 200 }), 1);
    await tick();
    expect((await t.http().post(api(`${base()}/session/login`)).set('X-Device-Token', 'stranger').send({ userId: 'u', pin: '1234' }).expect(401)).body.code).toBe('invalid_device_token');
    await t.http().get(api(`${base()}/state`)).expect(401);
    expect(await served).toEqual([]);
  });

  it('answers a print with its PDF and print headers', async () => {
    const served = serve(() => ({ status: 200, headers: { 'content-type': 'application/pdf', 'x-print-status': 'pdf' }, bodyB64: Buffer.from('%PDF').toString('base64') }));
    await tick();
    const r = await t.http().post(api(`${base()}/bills/b1/print`)).set('X-Device-Token', 'dev-token').send({}).expect(200);
    await served;
    expect(r.headers['content-type']).toBe('application/pdf');
    expect(r.headers['x-print-status']).toBe('pdf');
  });

  it('never relays pairing, the health probe or the WebSocket, however the path is spelled', async () => {
    expect((await t.http().post(api(`${base()}/pairing/staff-claim`)).send({ email: 'a@b.c', pin: '1234' }).expect(403)).body.code).toBe('not_relayed');
    await t.http().post(api(`${base()}/pairing/claim`)).send({ code: 'x' }).expect(403);
    await t.http().get(api(`${base()}/pairing/info`)).expect(403);
    await t.http().get(api(`${base()}/health`)).expect(403);
    await t.http().get(api(`${base()}/events`)).expect(403);
    for (const p of ['pairing%2Fstaff-claim', 'pairing/./staff-claim', 'pairing//staff-claim', 'x/../pairing/staff-claim', 'pairing/staff-claim%00', 'Pairing/Staff-Claim', 'EVENTS']) {
      await t.http().post(api(`${base()}/${p}`)).send({ email: 'a@b.c', pin: '1234' }).expect((r) => expect([400, 403, 404]).toContain(r.status));
    }
  });

  it('live events: only for a device the hub knows, in order, from the current position', async () => {
    const check = serve(() => ({ status: 200 }), 1);
    await tick();
    const start = (await t.http().get(api(`/relay/b/${R.branchId}/events`)).set('X-Device-Token', 'good').expect(200)).body;
    await check;
    expect(start).toMatchObject({ events: [], reset: false });
    const wait = t.http().get(api(`/relay/b/${R.branchId}/events?after=${start.seq}`)).set('X-Device-Token', 'good').then((r) => r);
    await tick();
    await t.http().post(api('/relay/hub/reply')).set('X-Device-Token', hub).send({ events: [{ type: 'order.updated', n: 1 }, { type: 'order.updated', n: 2 }] }).expect(200);
    const got = (await wait).body;
    expect(got.events.map((e: { n: number }) => e.n)).toEqual([1, 2]);
    expect(got.seq).toBe(start.seq + 2);

    const bad = serve(() => ({ status: 200 }), 1);
    await tick();
    await t.http().get(api(`/relay/b/${R.branchId}/events`)).set('X-Device-Token', 'bad').expect(401);
    await bad;
  });
});
