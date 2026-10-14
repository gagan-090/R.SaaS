/** Employees, custom roles, plan limits, and the staff web portal (email + PIN). */
import { randomInt } from 'crypto';
import { uuidv7 } from '../src/common/uuid';
import { pinProblem } from '../src/staff/pin-policy';
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

/** A random PIN that passes the policy (generated, so no fixed PIN sits in the repo). */
function goodPin(): string {
  for (;;) {
    const p = String(randomInt(100000, 99999999));
    if (!pinProblem(p)) return p;
  }
}
const mail = () => `emp-${uuidv7().slice(-10)}@example.test`;

describe('staff & staff web portal', () => {
  let t: TestApp;
  let saToken: string;
  let prem: Awaited<ReturnType<typeof onboardRestaurant>>;
  let std: Awaited<ReturnType<typeof onboardRestaurant>>;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const pinLogin = (email: string, pin: string) => t.http().post(api('/auth/pin-login')).send({ email, pin });

  beforeAll(async () => {
    t = await createTestApp();
    saToken = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    prem = await onboardRestaurant(t, saToken, 'premium');
    std = await onboardRestaurant(t, saToken, 'standard');
  });
  afterAll(() => t.close());

  describe('creating employees', () => {
    it('owner adds a waiter with email + PIN; the hub gets them; the PIN never reaches audit or responses', async () => {
      const pin = goodPin();
      const reg = (await t.http().post(api('/devices/register-hub')).set(bearer(prem.ownerToken)).send({ name: 'Hub', platform: 'android' }).expect(201)).body;
      const p0 = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', reg.deviceToken).expect(200)).body;
      const w = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Anita', email: mail(), role: 'waiter', pin }).expect(201)).body;
      expect(w).toMatchObject({ name: 'Anita', role: 'waiter', status: 'active', webAccess: false });
      const p1 = (await t.http().get(api(`/sync/pull?since=${p0.cursor}`)).set('X-Device-Token', reg.deviceToken).expect(200)).body;
      const pulled = p1.users.find((u: { id: string }) => u.id === w.id);
      expect(pulled.roles).toEqual([{ role: 'waiter', extraPermissions: [] }]);
      expect(pulled.pinHash).toMatch(/^\$argon2id\$/);
      const audit = await t.owner.auditEvent.findFirstOrThrow({ where: { action: 'staff.created', objectId: w.id } });
      expect(JSON.stringify(audit)).not.toContain(pin);
      const list = (await t.http().get(api('/staff')).set(bearer(prem.ownerToken)).expect(200)).body;
      const row = list.find((u: { id: string }) => u.id === w.id);
      expect(row).toMatchObject({ role: 'waiter', hasPin: true, webAccess: false, locked: false });
      expect(JSON.stringify(list)).not.toContain('argon2');
    });

    it('validates the form: email required, PIN policy, PIN or invite, unique email', async () => {
      const auth = bearer(prem.ownerToken);
      await t.http().post(api('/staff')).set(auth).send({ name: 'No email', role: 'waiter', pin: goodPin() }).expect(400);
      for (const weak of ['12', '1234', '111111', '123456', '987654', '123123']) {
        const r = await t.http().post(api('/staff')).set(auth).send({ name: 'Weak', email: mail(), role: 'waiter', pin: weak }).expect(400);
        expect(JSON.stringify(r.body)).toMatch(/PIN/);
      }
      await t.http().post(api('/staff')).set(auth).send({ name: 'Nothing', email: mail(), role: 'waiter' }).expect(400);
      const email = mail();
      await t.http().post(api('/staff')).set(auth).send({ name: 'One', email, role: 'waiter', pin: goodPin() }).expect(201);
      const dup = await t.http().post(api('/staff')).set(auth).send({ name: 'Two', email, role: 'cashier', pin: goodPin() }).expect(409);
      expect(dup.body.code).toBe('email_taken');
    });

    it('extended roles need the plan; web access needs the staff portal in the plan (direct API calls too)', async () => {
      const r = await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Kunal', email: mail(), role: 'chef', pin: goodPin() }).expect(403);
      expect(r.body.code).toBe('feature_not_in_plan');
      const w = await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Web', email: mail(), role: 'waiter', pin: goodPin(), webAccess: true }).expect(403);
      expect(w.body.code).toBe('feature_not_in_plan');
      await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Sohan', email: mail(), role: 'waiter', pin: goodPin() }).expect(201);
    });

    it('employee limit from the plan: the next active employee is refused, turned-off ones do not count', async () => {
      const code = `lim_${Date.now().toString(36)}`;
      await t.http().post(api('/plans')).set(bearer(saToken))
        .send({ code, name: 'Tiny', featureFlags: ['tables', 'menu', 'billing'], limits: { branches: 1, staffPerBranch: 1 }, pricePaise: 0 }).expect(201);
      const r = await onboardRestaurant(t, saToken, code);
      const auth = bearer(r.ownerToken);
      const first = (await t.http().post(api('/staff')).set(auth).send({ name: 'A', email: mail(), role: 'waiter', pin: goodPin() }).expect(201)).body;
      const over = await t.http().post(api('/staff')).set(auth).send({ name: 'B', email: mail(), role: 'waiter', pin: goodPin() }).expect(403);
      expect(over.body.code).toBe('employee_limit');
      const off = (await t.http().post(api('/staff')).set(auth).send({ name: 'C', email: mail(), role: 'waiter', pin: goodPin(), status: 'disabled' }).expect(201)).body;
      await t.http().patch(api(`/staff/${off.id}`)).set(auth).send({ status: 'active' }).expect(403);
      await t.http().patch(api(`/staff/${first.id}`)).set(auth).send({ status: 'disabled' }).expect(200);
      await t.http().patch(api(`/staff/${off.id}`)).set(auth).send({ status: 'active' }).expect(200);
      const lim = (await t.http().get(api('/staff/limits')).set(auth).expect(200)).body;
      expect(lim).toMatchObject({ employeeLimit: 1, activeEmployees: 1, staffPortal: false });
    });
  });

  describe('Restaurant Admin authority', () => {
    let admin: string;
    beforeAll(async () => {
      const email = mail();
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Imran', email, role: 'it_admin', pin: goodPin(), password: 'Admin-pass-' + uuidv7().slice(-6) }).expect(201);
      const pinAdmin = goodPin();
      const row = await t.owner.user.findFirstOrThrow({ where: { email } });
      await t.http().patch(api(`/staff/${row.id}`)).set(bearer(prem.ownerToken)).send({ pin: pinAdmin, webAccess: true }).expect(200);
      admin = (await pinLogin(email, pinAdmin).expect(200)).body.accessToken;
    });

    it('creates ordinary employees, but never another admin, discounts they lack, or a custom role beyond their own permissions', async () => {
      await t.http().post(api('/staff')).set(bearer(admin)).send({ name: 'Ravi', email: mail(), role: 'cashier', pin: goodPin() }).expect(201);
      expect((await t.http().post(api('/staff')).set(bearer(admin)).send({ name: 'X', email: mail(), role: 'it_admin', pin: goodPin() }).expect(403)).body.code).toBe('owner_only');
      expect((await t.http().post(api('/staff')).set(bearer(admin)).send({ name: 'X', email: mail(), role: 'cashier', pin: goodPin(), canDiscount: true }).expect(403)).body.code).toBe('beyond_authority');
      // custom roles: the owner makes them; the admin may hand out only those within their own permissions
      await t.http().post(api('/roles')).set(bearer(admin)).send({ name: 'Nope', permissions: ['floor.read'] }).expect(403);
      const host = (await t.http().post(api('/roles')).set(bearer(prem.ownerToken)).send({ name: 'Host', permissions: ['floor.read', 'floor.manage', 'order.read'] }).expect(201)).body;
      const cash = (await t.http().post(api('/roles')).set(bearer(prem.ownerToken)).send({ name: 'Cash desk', permissions: ['payment.take', 'order.read'] }).expect(201)).body;
      await t.http().post(api('/staff')).set(bearer(admin)).send({ name: 'Meera', email: mail(), role: 'custom', customRoleId: host.id, pin: goodPin() }).expect(201);
      const beyond = await t.http().post(api('/staff')).set(bearer(admin)).send({ name: 'Z', email: mail(), role: 'custom', customRoleId: cash.id, pin: goodPin() }).expect(403);
      expect(beyond.body.code).toBe('beyond_authority');
      const ownerRow = await t.http().patch(api(`/staff/${prem.ownerUserId}`)).set(bearer(admin)).send({ status: 'disabled' }).expect(403);
      expect(ownerRow.body.code).toBe('owner_protected');
    });
  });

  describe('custom roles', () => {
    it('a custom role grants exactly its permissions, on the web and on the hub; unknown or out-of-plan permissions are refused', async () => {
      const auth = bearer(prem.ownerToken);
      await t.http().post(api('/roles')).set(auth).send({ name: 'Bad', permissions: ['launch.rockets'] }).expect(400);
      const role = (await t.http().post(api('/roles')).set(auth).send({ name: `Floor lead ${uuidv7().slice(-4)}`, permissions: ['floor.read', 'floor.manage', 'order.read', 'order.write'] }).expect(201)).body;
      const email = mail(), pin = goodPin();
      const u = (await t.http().post(api('/staff')).set(auth).send({ name: 'Lead', email, role: 'custom', customRoleId: role.id, pin, webAccess: true }).expect(201)).body;
      const tok = (await pinLogin(email, pin).expect(200)).body.accessToken;
      const me = (await t.http().get(api('/me')).set(bearer(tok)).expect(200)).body;
      expect(me.permissions).toEqual(expect.arrayContaining(['floor.manage', 'order.write']));
      expect(me.permissions).not.toContain('menu.publish');
      expect(me.customRoleName).toBe(role.name);
      await t.http().get(api('/floors')).set(bearer(tok)).expect(200);
      await t.http().get(api('/staff')).set(bearer(tok)).expect(403);
      // the hub pulls the role's permissions
      const reg = (await t.http().post(api('/devices/register-hub')).set(auth).send({ name: 'Hub 2', platform: 'android' }).expect(201)).body;
      const pull = (await t.http().get(api('/sync/pull?since=0')).set('X-Device-Token', reg.deviceToken).expect(200)).body;
      expect(pull.users.find((x: { id: string }) => x.id === u.id).roles[0]).toMatchObject({ role: 'custom', permissions: expect.arrayContaining(['order.write']) });
      // changing the role changes access on the next request; a role in use cannot be deleted
      await t.http().patch(api(`/roles/${role.id}`)).set(auth).send({ permissions: ['floor.read'] }).expect(200);
      expect((await t.http().get(api('/me')).set(bearer(tok)).expect(200)).body.permissions).not.toContain('floor.manage');
      expect((await t.http().delete(api(`/roles/${role.id}`)).set(auth).expect(409)).body.code).toBe('role_in_use');
      // a plan without custom roles: refused even by direct API call
      expect((await t.http().post(api('/roles')).set(bearer(std.ownerToken)).send({ name: 'X', permissions: ['floor.read'] }).expect(403)).body.code).toBe('feature_not_in_plan');
    });
  });

  describe('email + PIN sign-in', () => {
    it('invite link: the employee chooses their own PIN, the link works once, then they sign in and land with their role', async () => {
      const email = mail();
      const c = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Chef K', email, role: 'chef', sendInvite: true, webAccess: true }).expect(201)).body;
      expect(c.invite).toEqual({ emailSent: true });
      const token = t.mailer.lastTokenFor(email);
      expect((await t.http().post(api('/auth/pin-link/check')).send({ token }).expect(200)).body).toMatchObject({ name: 'Chef K', purpose: 'invite' });
      await t.http().post(api('/auth/pin-link/complete')).send({ token, pin: '123456' }).expect(400);
      const pin = goodPin();
      await t.http().post(api('/auth/pin-link/complete')).send({ token, pin }).expect(200);
      await t.http().post(api('/auth/pin-link/complete')).send({ token, pin: goodPin() }).expect(400); // once only
      const ok = (await pinLogin(email, pin).expect(200)).body;
      const me = (await t.http().get(api('/me')).set(bearer(ok.accessToken)).expect(200)).body;
      expect(me.roles).toEqual(['chef']);
      expect(me.permissions).toEqual(expect.arrayContaining(['inventory.consume', 'inventory.request', 'kds.update']));
      expect(me.permissions).not.toContain('inventory.write');
      // logout ends the session
      await t.http().post(api('/auth/logout')).set(bearer(ok.accessToken)).send({ refreshToken: ok.refreshToken }).expect((r) => expect([200, 204]).toContain(r.status));
      await t.http().post(api('/auth/refresh')).send({ refreshToken: ok.refreshToken }).expect(401);
    });

    it('wrong PINs lock the account for 15 minutes; the owner can unlock; each refusal is audited without the PIN', async () => {
      const email = mail(), pin = goodPin();
      const u = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Lock', email, role: 'cashier', pin, webAccess: true }).expect(201)).body;
      for (let i = 0; i < 5; i++) await pinLogin(email, goodPin() === pin ? '0000000' : goodPin()).expect(401);
      expect((await pinLogin(email, pin).expect(401)).body.code).toBe('account_locked');
      expect((await t.http().get(api('/staff')).set(bearer(prem.ownerToken)).expect(200)).body.find((x: { id: string }) => x.id === u.id).locked).toBe(true);
      await t.http().post(api(`/staff/${u.id}/unlock`)).set(bearer(prem.ownerToken)).expect(200);
      await pinLogin(email, pin).expect(200);
      const fails = await t.owner.auditEvent.findMany({ where: { action: 'auth.login_failed', objectId: u.id } });
      expect(fails.length).toBeGreaterThanOrEqual(5);
      expect(JSON.stringify(fails)).not.toContain(pin);
    });

    it('refuses: no web access, owners, unknown emails, a plan without the portal, and old short PINs', async () => {
      const email = mail(), pin = goodPin();
      const u = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'NoWeb', email, role: 'waiter', pin }).expect(201)).body;
      expect((await pinLogin(email, pin).expect(403)).body.code).toBe('no_web_access');
      expect((await pinLogin(mail(), pin).expect(401)).body.code).toBe('invalid_credentials');
      // owner signs in with a password
      await t.owner.user.update({ where: { id: prem.ownerUserId }, data: { pinHash: (await t.owner.user.findUniqueOrThrow({ where: { id: u.id } })).pinHash } });
      expect((await pinLogin(prem.ownerEmail, pin).expect(403)).body.code).toBe('use_password');
      // a restaurant whose plan lacks the portal, even if the flag was set directly in the database
      const s = await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Std', email: mail(), role: 'waiter', pin }).expect(201);
      const stdRow = await t.owner.user.update({ where: { id: s.body.id }, data: { webAccess: true } });
      expect((await pinLogin(stdRow.email!, pin).expect(403)).body.code).toBe('feature_not_in_plan');
      // a legacy 4-digit PIN works on the POS but not on the web
      const legacy = await addStaff(t, prem.tenantId, 'waiter');
      const argon2 = await import('argon2');
      const lu = await t.owner.user.update({ where: { id: legacy.id }, data: { webAccess: true, pinHash: await argon2.hash('4821', { type: argon2.argon2id }) } });
      expect((await pinLogin(lu.email!, '4821').expect(403)).body.code).toBe('pin_change_required');
    });

    it('turning an employee off ends access immediately, even with a token already issued', async () => {
      const email = mail(), pin = goodPin();
      const u = (await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Leaver', email, role: 'auditor', pin, webAccess: true }).expect(201)).body;
      const s = (await pinLogin(email, pin).expect(200)).body;
      await t.http().get(api('/tenant/overview')).set(bearer(s.accessToken)).expect(200);
      await t.http().patch(api(`/staff/${u.id}`)).set(bearer(prem.ownerToken)).send({ status: 'disabled' }).expect(200);
      expect((await t.http().get(api('/tenant/overview')).set(bearer(s.accessToken)).expect(401)).body.code).toBe('inactive_account');
      await t.http().post(api('/auth/refresh')).send({ refreshToken: s.refreshToken }).expect(401);
      expect((await pinLogin(email, pin).expect(403)).body.code).toBe('inactive_account');
    });

    it('forgot PIN answers the same for unknown emails and mails a reset link only to eligible employees', async () => {
      const email = mail(), pin = goodPin();
      await t.http().post(api('/staff')).set(bearer(prem.ownerToken)).send({ name: 'Forgetful', email, role: 'waiter', pin, webAccess: true }).expect(201);
      const before = t.mailer.sent.length;
      const unknown = (await t.http().post(api('/auth/pin-reset-request')).send({ email: mail() }).expect(202)).body;
      expect(t.mailer.sent.length).toBe(before);
      const known = (await t.http().post(api('/auth/pin-reset-request')).send({ email }).expect(202)).body;
      expect(known).toEqual(unknown);
      const token = t.mailer.lastTokenFor(email);
      const fresh = goodPin();
      await t.http().post(api('/auth/pin-link/complete')).send({ token, pin: fresh }).expect(200);
      await pinLogin(email, pin).expect(401);
      await pinLogin(email, fresh).expect(200);
    });
  });

  describe('isolation', () => {
    it("an owner cannot see or change another restaurant's employees", async () => {
      const other = (await t.http().post(api('/staff')).set(bearer(std.ownerToken)).send({ name: 'Theirs', email: mail(), role: 'waiter', pin: goodPin() }).expect(201)).body;
      const list = (await t.http().get(api('/staff')).set(bearer(prem.ownerToken)).expect(200)).body;
      expect(list.some((u: { id: string }) => u.id === other.id)).toBe(false);
      await t.http().patch(api(`/staff/${other.id}`)).set(bearer(prem.ownerToken)).send({ name: 'Mine now' }).expect(404);
      await t.http().post(api(`/staff/${other.id}/pin-link`)).set(bearer(prem.ownerToken)).expect(404);
    });

    it('cashiers cannot manage staff', async () => {
      const cashier = await addStaff(t, prem.tenantId, 'cashier');
      await t.http().post(api('/staff')).set(bearer(cashier.token)).send({ name: 'x', email: mail(), role: 'waiter', pin: goodPin() }).expect(403);
      await t.http().get(api('/staff')).set(bearer(cashier.token)).expect(403);
    });
  });
});
