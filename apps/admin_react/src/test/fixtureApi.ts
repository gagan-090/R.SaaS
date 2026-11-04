/* eslint-disable @typescript-eslint/no-explicit-any */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { vi } from 'vitest';

/**
 * Serves the recorded contract fixtures (packages/contracts/fixtures) as a fake cloud API, so tests exercise the
 * exact JSON shapes the real API returns. Port of apps/admin_web/test/fixture_api.dart.
 */
const dir = resolve(__dirname, '../../../../packages/contracts/fixtures');
export const fixture = (file: string): any => JSON.parse(readFileSync(resolve(dir, file), 'utf8')).response;

const routes: [string, RegExp, string][] = [
  ['POST', /^\/auth\/login$/, 'POST_auth_login.mfa_required.json'],
  ['POST', /^\/auth\/mfa\/verify$/, 'POST_auth_mfa_verify.json'],
  ['POST', /^\/auth\/step-up$/, 'POST_auth_step_up.json'],
  ['POST', /^\/auth\/refresh$/, 'POST_auth_refresh.json'],
  ['POST', /^\/auth\/logout$/, ''],
  ['GET', /^\/me$/, 'GET_me.json'],
  ['GET', /^\/restaurants$/, 'GET_restaurants.json'],
  ['GET', /^\/restaurants\/[^/]+$/, 'GET_restaurants_id.json'],
  ['POST', /^\/restaurants\/[^/]+\/status$/, 'POST_restaurants_id_status.suspend.json'],
  ['GET', /^\/plans$/, 'GET_plans.json'],
  ['PATCH', /^\/plans\/[^/]+$/, 'PATCH_plans_id.json'],
  ['POST', /^\/plans$/, 'POST_plans.json'],
  ['GET', /^\/platform\/admins$/, 'GET_platform_admins.json'],
  ['GET', /^\/platform\/roles$/, 'GET_platform_roles.json'],
  ['POST', /^\/platform\/admins\/[^/]+\/mfa\/reset$/, 'POST_platform_admins_id_mfa_reset.json'],
  ['GET', /^\/platform\/audit$/, 'GET_platform_audit.json'],
  ['POST', /^\/restaurants\/verify-email$/, 'POST_restaurants_verify_email.json'],
];

export type Call = { method: string; path: string; query: URLSearchParams; body: any; headers: Record<string, string> };

export class FixtureApi {
  calls: Call[] = [];
  /** 'POST /auth/login' → [status, body] (or a function of the call). */
  overrides = new Map<string, [number, unknown] | ((c: Call) => [number, unknown])>();

  install() {
    vi.stubGlobal('fetch', vi.fn(this.handle));
    return this;
  }

  set(key: string, status: number, body: unknown) {
    this.overrides.set(key, [status, body]);
    return this;
  }

  where = (method: string, part: string) => this.calls.filter((c) => c.method === method && c.path.includes(part));

  private handle = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const path = url.pathname.replace('/api/v1', '');
    const method = (init?.method ?? 'GET').toUpperCase();
    const call: Call = { method, path, query: url.searchParams, body: init?.body ? JSON.parse(String(init.body)) : undefined, headers: (init?.headers as Record<string, string>) ?? {} };
    this.calls.push(call);
    const json = (status: number, body: unknown) => new Response(body === undefined ? '' : JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
    const key = `${method} ${path}`;
    const o = this.overrides.get(key);
    if (o) {
      const [s, b] = typeof o === 'function' ? o(call) : o;
      return json(s, b);
    }
    if (method === 'GET' && path === '/restaurants/registrations') return json(200, { counts: { awaiting: 0, expired: 0 }, items: [] });
    if (method === 'GET' && path === '/platform/attention')
      return json(200, { counts: {}, overdueLicenses: [], upcomingLicenses: [], suspendedTenants: [], archivedTenants: [], awaitingRegistrations: [] });
    for (const [m, re, file] of routes) {
      if (m === method && re.test(path)) return file === '' ? new Response(null, { status: 204 }) : json(200, fixture(file));
    }
    return json(404, { code: 'not_mocked', message: `${key} not mocked` });
  };
}
