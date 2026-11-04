import { describe, expect, test } from 'vitest';
import { ApiClient, ApiException } from '../api/client';

/** A fetch that answers per "METHOD /path" and records calls. */
function fakeFetch(answer: (method: string, path: string, body: Record<string, unknown> | undefined, auth: string | undefined) => [number, unknown]) {
  const calls: { method: string; path: string; auth?: string }[] = [];
  const f = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const u = new URL(String(input));
    const method = init?.method ?? 'GET';
    const path = u.pathname.replace('/api/v1', '');
    const auth = (init?.headers as Record<string, string> | undefined)?.authorization;
    calls.push({ method, path, auth });
    const [s, b] = answer(method, path, init?.body ? JSON.parse(String(init.body)) : undefined, auth);
    return new Response(b === undefined ? '' : JSON.stringify(b), { status: s });
  }) as typeof fetch;
  return { f, calls };
}

describe('session (port of session_test.dart)', () => {
  test('reload rotates the saved refresh token and logout clears it', async () => {
    let saved: string | null = 'r1';
    const { f, calls } = fakeFetch((_m, p, body) => {
      if (p === '/auth/refresh') return [200, { accessToken: 'a2', refreshToken: body?.refreshToken === 'r1' ? 'r2' : 'x' }];
      if (p === '/auth/logout') return [204, undefined];
      return [404, {}];
    });
    const api = new ApiClient('http://api/api/v1', f, () => saved, (v) => (saved = v));
    expect(await api.restoreSession()).toBe(true);
    expect(api.accessToken).toBe('a2');
    expect(saved).toBe('r2');
    await api.logout();
    expect(saved).toBeNull();
    expect(calls.map((c) => c.path)).toEqual(['/auth/refresh', '/auth/logout']);
  });

  test('expired saved session is cleared', async () => {
    let saved: string | null = 'old';
    const { f } = fakeFetch(() => [401, { code: 'invalid_refresh', message: 'Session expired' }]);
    const api = new ApiClient('http://api/api/v1', f, () => saved, (v) => (saved = v));
    expect(await api.restoreSession()).toBe(false);
    expect(saved).toBeNull();
  });

  test('a 401 refreshes once and retries with the new token; parallel 401s share one refresh', async () => {
    let refreshes = 0;
    const { f, calls } = fakeFetch((_m, p, _body, auth) => {
      if (p === '/auth/refresh') return refreshes++, [200, { accessToken: 'fresh', refreshToken: 'r9' }];
      return auth === 'Bearer fresh' ? [200, { ok: true }] : [401, { code: 'expired', message: 'Expired' }];
    });
    const api = new ApiClient('http://api/api/v1', f, () => null, () => undefined);
    api.accessToken = 'stale';
    api.refreshToken = 'r1';
    const [a, b] = await Promise.all([api.me(), api.overview()]);
    expect(a).toEqual({ ok: true });
    expect(b).toEqual({ ok: true });
    expect(refreshes).toBe(1);
    expect(calls.filter((c) => c.path === '/me')).toHaveLength(2);
  });

  test('a failed refresh signs the person out', async () => {
    let expired = false;
    const { f } = fakeFetch((_m, p) => (p === '/auth/refresh' ? [401, {}] : [401, { code: 'expired', message: 'Expired' }]));
    const api = new ApiClient('http://api/api/v1', f, () => null, () => undefined);
    api.onSessionExpired = () => (expired = true);
    api.accessToken = 'stale';
    api.refreshToken = 'r1';
    await expect(api.me()).rejects.toBeInstanceOf(ApiException);
    expect(expired).toBe(true);
  });

  test('errors carry the server code and message', async () => {
    const { f } = fakeFetch(() => [403, { code: 'feature_not_in_plan', message: 'Not in your plan' }]);
    const api = new ApiClient('http://api/api/v1', f, () => null, () => undefined);
    const e = await api.expenses().catch((x) => x);
    expect(e).toBeInstanceOf(ApiException);
    expect(e.code).toBe('feature_not_in_plan');
    expect(e.message).toBe('Not in your plan');
  });
});
