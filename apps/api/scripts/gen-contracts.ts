/**
 * Generates packages/contracts:
 *   openapi.json        — OpenAPI 3 from the live Nest app (routes, auth, zod-derived request schemas) + recorded examples
 *   fixtures/*.json     — one REAL request/response pair per endpoint, recorded by driving the API end to end
 *   fixtures/INDEX.md   — list of endpoints and fixture files
 * Secrets in responses (tokens, TOTP secrets, recovery codes) are replaced with placeholders.
 * Usage: pnpm --filter @rsaas/api openapi   (always runs against the isolated <db>_test database — never your dev data)
 */
import './contracts-env'; // must run first: points the app at the isolated _test database
import * as fs from 'fs';
import * as path from 'path';
import { authenticator } from 'otplib';
import { buildOpenApi } from '../src/bootstrap';
import { uuidv7 } from '../src/common/uuid';
import { createAdmin, createTestApp, listRoutes, TestApp, totp, uniq } from '../test/helpers';

const OUT = path.resolve(__dirname, '../../../packages/contracts');
const FIX = path.join(OUT, 'fixtures');

type Json = unknown;
interface Fixture {
  method: string;
  path: string;
  example: string;
  auth: 'none' | 'bearer' | 'device';
  request?: { headers?: Record<string, string>; query?: Record<string, string>; body?: Json };
  status: number;
  response: Json;
}

const SECRET_KEYS = /^(accessToken|refreshToken|challengeToken|enrollmentToken|stepUpToken|deviceToken|token|secret|signedToken|licenseToken|publicKey|pinHash|passwordHash|deviceTokenHash|totpSecretEncrypted|recoveryCodeHashes|tokenHash|otpauthUrl|password)$/;
function scrub(v: Json, key = ''): Json {
  if (SECRET_KEYS.test(key) && typeof v === 'string') return `<${key}>`;
  if (key === 'recoveryCodes' && Array.isArray(v)) return v.map((_, i) => `<recovery-code-${i + 1}>`);
  if (Array.isArray(v)) return v.map((x) => scrub(x));
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, scrub(x, k)]));
  return v;
}

async function main() {
  const t: TestApp = await createTestApp();
  const fixtures: Fixture[] = [];
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });

  async function call(method: 'get' | 'post' | 'patch' | 'delete', template: string, opts: {
    params?: Record<string, string>; token?: string; device?: string; body?: Json; query?: Record<string, string>; headers?: Record<string, string>; name?: string; expect?: number;
  } = {}) {
    let url = template;
    for (const [k, v] of Object.entries(opts.params ?? {})) url = url.replace(`:${k}`, v);
    const full = (template.startsWith('/health') ? '' : '/api/v1') + url + (opts.query ? '?' + new URLSearchParams(opts.query).toString() : '');
    let req = t.http()[method](full);
    if (opts.token) req = req.set(bearer(opts.token));
    if (opts.device) req = req.set('X-Device-Token', opts.device);
    for (const [k, v] of Object.entries(opts.headers ?? {})) req = req.set(k, v);
    const res = await (opts.body !== undefined ? req.send(opts.body as object) : req);
    if (opts.expect && res.status !== opts.expect) throw new Error(`${method.toUpperCase()} ${full} → ${res.status} ${JSON.stringify(res.body)}`);
    fixtures.push({
      method: method.toUpperCase(),
      path: (template.startsWith('/health') ? '' : '/api/v1') + template,
      example: opts.name ?? 'ok',
      auth: opts.token ? 'bearer' : opts.device ? 'device' : 'none',
      request: {
        headers: opts.headers ? Object.fromEntries(Object.keys(opts.headers).map((k) => [k, `<${k}>`])) : undefined,
        query: opts.query,
        body: opts.body === undefined ? undefined : scrub(opts.body),
      },
      status: res.status,
      response: scrub(res.body),
    });
    return res.body;
  }

  // ---------------- auth
  await call('get', '/health', { expect: 200 });
  const sa = await createAdmin(t, ['Super Admin']);
  const l1 = await call('post', '/auth/login', { body: { email: sa.email, password: sa.password }, expect: 200, name: 'mfa_required' });
  const sat = await call('post', '/auth/mfa/verify', { body: { challengeToken: l1.challengeToken, code: totp(sa.secret) }, expect: 200 });
  const fresh = await createAdmin(t, ['Platform Auditor'], { mfa: false });
  const l2 = await call('post', '/auth/login', { body: { email: fresh.email, password: fresh.password }, expect: 200, name: 'mfa_enrollment_required' });
  const en = await call('post', '/me/mfa/enroll', { token: l2.enrollmentToken, expect: 200 });
  await call('post', '/me/mfa/confirm', { token: l2.enrollmentToken, body: { code: authenticator.generate(en.secret) }, expect: 200 });
  const ref = await call('post', '/auth/refresh', { body: { refreshToken: sat.refreshToken }, expect: 200 });
  const tok = ref.accessToken as string;
  await call('get', '/me', { token: tok, expect: 200 });
  const step = await call('post', '/auth/step-up', { token: tok, body: { password: sa.password, code: totp(sa.secret, 1) }, expect: 200 });

  // ---------------- plans
  await call('get', '/plans', { token: tok, expect: 200 });
  const plan = await call('post', '/plans', { token: tok, expect: 201, body: { code: `trial_${Date.now().toString(36)}`, name: 'Trial', featureFlags: ['tables', 'menu', 'billing'], limits: { branches: 1 }, pricePaise: 0, billingCycle: 'monthly' } });
  await call('patch', '/plans/:id', { token: tok, params: { id: plan.id }, body: { pricePaise: 49900 }, expect: 200 });

  // ---------------- restaurants & licensing
  const ownerEmail = `${uniq('owner')}@example.test`;
  const ownerPassword = 'Owner-' + uniq();
  await call('post', '/restaurants', { token: tok, expect: 201, body: { ownerEmail, ownerName: 'Asha Rao', restaurantName: 'Spice Route', gstin: '27AAAPA1234A1Z5', address: 'FC Road, Pune', planCode: 'premium' } });
  const ver = await call('post', '/restaurants/verify-email', { expect: 201, body: { token: t.mailer.lastTokenFor(ownerEmail), password: ownerPassword } });
  const rid = ver.tenantId as string;
  await call('get', '/restaurants', { token: tok, query: { status: 'active', plan: 'premium', page: '1', pageSize: '25' }, expect: 200 });
  await call('get', '/restaurants/:id', { token: tok, params: { id: rid }, expect: 200 });
  await call('patch', '/restaurants/:id', { token: tok, params: { id: rid }, body: { address: 'FC Road, Shivajinagar, Pune' }, expect: 200 });
  await call('post', '/restaurants/:id/status', { token: tok, params: { id: rid }, body: { action: 'suspend', reason: 'Subscription unpaid' }, expect: 200, name: 'suspend' });
  await call('post', '/restaurants/:id/status', { token: tok, params: { id: rid }, body: { action: 'reactivate', reason: 'Payment received' }, expect: 200, name: 'reactivate' });
  await call('post', '/restaurants/:id/licenses', { token: tok, params: { id: rid }, body: { action: 'renew', reason: 'Annual renewal' }, expect: 201 });
  await call('get', '/restaurants/:id/licenses', { token: tok, params: { id: rid }, expect: 200 });
  await call('get', '/restaurants/:id/licenses/current/token', { token: tok, params: { id: rid }, expect: 200 });
  await call('post', '/restaurants/:id/payments', { token: tok, params: { id: rid }, body: { amountPaise: 99900, method: 'upi', reference: 'UTR4455', paidAt: new Date().toISOString() }, expect: 201 });

  // ---------------- platform admins
  await call('get', '/platform/admins', { token: tok, expect: 200 });
  const roles = await call('get', '/platform/roles', { token: tok, expect: 200 });
  await call('get', '/platform/permissions', { token: tok, expect: 200 });
  const auditorRole = (roles as { id: string; name: string }[]).find((r) => r.name === 'Platform Auditor')!;
  const onboardingRole = (roles as { id: string; name: string }[]).find((r) => r.name === 'Onboarding Admin')!;
  await call('post', '/platform/admins/create', { token: tok, expect: 201, body: { email: `${uniq('direct-admin')}@example.test`, name: 'Direct Admin', password: 'Direct-' + uniq() } });
  const pending = await t.http().post('/api/v1/platform/admins').set(bearer(tok)).send({ email: `${uniq('pending-admin')}@example.test`, name: 'Pending Admin', roleIds: [auditorRole.id] }).expect(201);
  await call('post', '/platform/admins/:id/activate', { token: tok, params: { id: pending.body.id }, expect: 200, body: { password: 'Activate-' + uniq() } });
  const invEmail = `${uniq('admin')}@example.test`;
  const inv = await call('post', '/platform/admins', { token: tok, expect: 201, body: { email: invEmail, name: 'Neha Support', roleIds: [auditorRole.id] } });
  await call('post', '/auth/accept-invite', { expect: 200, body: { token: t.mailer.lastTokenFor(invEmail), password: 'Invitee-' + uniq() } });
  await call('post', '/platform/roles', { token: tok, expect: 201, body: { name: `Support ${uniq()}`, description: 'Reads restaurants', permissions: ['platform.restaurant.read'] } });
  await call('patch', '/platform/admins/:id/roles', { token: tok, params: { id: inv.id }, body: { roleIds: [auditorRole.id, onboardingRole.id] }, expect: 200 });
  const target = await createAdmin(t, ['Platform Auditor']);
  await call('post', '/platform/admins/:id/mfa/reset', { token: tok, params: { id: target.id }, headers: { 'X-Step-Up-Token': step.stepUpToken }, body: { reason: 'Lost phone; identity verified on call' }, expect: 200 });
  await call('post', '/platform/admins/:id/mfa/reset', { token: tok, params: { id: target.id }, body: { reason: 'no step-up' }, name: 'error_step_up_required', expect: 403 });
  await call('post', '/platform/admins/:id/deactivate', { token: tok, params: { id: inv.id }, body: { reason: 'Left the company' }, expect: 200 });
  await call('get', '/platform/audit', { token: tok, query: { action: 'restaurant', pageSize: '5' }, expect: 200 });

  // ---------------- restaurant owner (tenant routes)
  const ol = await call('post', '/auth/login', { body: { email: ownerEmail, password: ownerPassword }, expect: 200, name: 'ok_restaurant_user' });
  const ot = ol.accessToken as string;
  await call('get', '/tenant/profile', { token: ot, expect: 200 });
  await call('patch', '/tenant/profile', { token: ot, body: { name: 'Spice Route Kitchen' }, expect: 200 });
  await call('get', '/tenant/license', { token: ot, expect: 200 });
  await call('get', '/branches', { token: ot, expect: 200 });
  const floor = await call('post', '/floors', { token: ot, body: { branchId: ver.branchId, name: 'Ground floor', sortOrder: 0 }, expect: 201 });
  await call('patch', '/floors/:id', { token: ot, params: { id: floor.id }, body: { name: 'Ground floor (AC)' }, expect: 200 });
  const table = await call('post', '/tables', { token: ot, body: { floorId: floor.id, name: '12', seats: 4, layoutX: 2, layoutY: 1 }, expect: 201 });
  const t2 = await call('post', '/tables', { token: ot, body: { floorId: floor.id, name: '13', seats: 2 }, expect: 201, name: 'second' });
  await call('patch', '/tables/:id', { token: ot, params: { id: table.id }, body: { seats: 6 }, expect: 200 });
  await call('delete', '/tables/:id', { token: ot, params: { id: t2.id }, expect: 204 });
  await call('get', '/floors', { token: ot, expect: 200 });
  await call('get', '/tables', { token: ot, expect: 200 });
  const tax = await call('post', '/tax-rules', { token: ot, body: { name: 'GST 5%', rateBp: 500 }, expect: 201 });
  await call('get', '/tax-rules', { token: ot, expect: 200 });
  const cat = await call('post', '/menu/categories', { token: ot, body: { name: 'Mains', sortOrder: 1 }, expect: 201 });
  await call('get', '/menu/categories', { token: ot, expect: 200 });
  const item = await call('post', '/menu/items', { token: ot, expect: 201, body: { categoryId: cat.id, name: 'Butter Chicken', description: 'Tomato-butter gravy', pricePaise: 34000, taxRuleId: tax.id, isVeg: false, plateColors: { base: '#D9622B', sauce: '#F2C27B', garnish: '#4F8A3B' } } });
  await call('patch', '/menu/items/:id', { token: ot, params: { id: item.id }, body: { pricePaise: 35000 }, expect: 200 });
  await call('get', '/menu/items', { token: ot, expect: 200 });
  await call('get', '/menu/items/:id', { token: ot, params: { id: item.id }, expect: 200 });
  await call('get', '/users', { token: ot, expect: 200 });
  await call('get', '/audit', { token: ot, expect: 200 });
  await call('get', '/restaurants', { token: ot, name: 'error_missing_permission', expect: 403 });

  // ---------------- hub device & sync
  const dev = await call('post', '/devices/register-hub', { token: ot, body: { branchId: ver.branchId, name: 'Cashier PC', platform: 'windows' }, expect: 201 });
  const ev = { eventId: uuidv7(), entity: 'order', entityId: uuidv7(), op: 'create', payload: { branchId: ver.branchId, type: 'dine_in', tableId: table.id }, createdAt: new Date().toISOString() };
  await call('post', '/sync/push', { device: dev.deviceToken, body: { events: [ev] }, expect: 200 });
  await call('post', '/sync/push', { device: dev.deviceToken, body: { events: [ev, { ...ev, eventId: uuidv7(), entity: 'menu_item' }] }, expect: 200, name: 'duplicate_and_rejected' });
  await call('get', '/sync/pull', { device: dev.deviceToken, query: { since: '0' }, expect: 200 });
  await call('get', '/sync/status', { device: dev.deviceToken, expect: 200 });
  await call('post', '/auth/logout', { token: ot, body: { refreshToken: ol.refreshToken }, expect: 204 });

  // ---------------- write fixtures + OpenAPI
  fs.rmSync(FIX, { recursive: true, force: true });
  fs.mkdirSync(FIX, { recursive: true });
  const fileOf = (f: Fixture) => `${f.method}${f.path.replace(/^\/api\/v1/, '').replace(/[/:-]+/g, '_')}${f.example === 'ok' ? '' : '.' + f.example}.json`.replace(/_+/g, '_');
  for (const f of fixtures) fs.writeFileSync(path.join(FIX, fileOf(f)), JSON.stringify(f, null, 2) + '\n');

  const doc = buildOpenApi(t.app) as unknown as { paths: Record<string, Record<string, Record<string, unknown>>> };
  const routes = listRoutes(t.app);
  const missing: string[] = [];
  for (const r of routes) {
    const oaPath = r.path.replace(/:(\w+)/g, '{$1}');
    const op = doc.paths[oaPath]?.[r.method.toLowerCase()];
    const mine = fixtures.filter((f) => f.method === r.method && f.path === r.path);
    if (!mine.length) missing.push(`${r.method} ${r.path}`);
    if (!op) continue;
    op['x-fixtures'] = mine.map((f) => `fixtures/${fileOf(f)}`);
    const reqEx = mine.find((f) => f.request?.body !== undefined);
    const rb = op.requestBody as { content?: Record<string, { examples?: object }> } | undefined;
    if (reqEx && rb?.content?.['application/json']) rb.content['application/json'].examples = { recorded: { value: reqEx.request!.body } };
    const responses = (op.responses ?? {}) as Record<string, { description: string; content?: object }>;
    for (const f of mine) {
      const key = String(f.status);
      responses[key] = {
        description: responses[key]?.description || (f.status < 400 ? 'Success' : 'Error'),
        ...(f.status === 204 ? {} : { content: { 'application/json': { examples: { [f.example]: { value: f.response } } } } }),
      };
    }
    op.responses = responses;
    if (fixtures.some((f) => f.path === r.path && f.auth === 'device')) op.parameters = [...((op.parameters as object[]) ?? []), { name: 'X-Device-Token', in: 'header', required: true, schema: { type: 'string' } }];
  }
  fs.writeFileSync(path.join(OUT, 'openapi.json'), JSON.stringify(doc, null, 2) + '\n');
  const index = ['# Mock fixtures', '', 'Recorded from a real run of the API (`pnpm --filter @rsaas/api openapi`). Tokens/secrets are placeholders.', '', '| Method | Path | Example | Status | File |', '| --- | --- | --- | --- | --- |',
    ...fixtures.map((f) => `| ${f.method} | \`${f.path}\` | ${f.example} | ${f.status} | [${fileOf(f)}](${fileOf(f)}) |`)];
  fs.writeFileSync(path.join(FIX, 'INDEX.md'), index.join('\n') + '\n');
  console.log(`wrote openapi.json (${routes.length} routes) and ${fixtures.length} fixtures`);
  if (missing.length) {
    console.error('Routes without a fixture:\n  ' + missing.join('\n  '));
    process.exitCode = 1;
  }
  await t.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
