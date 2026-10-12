/** Auth routes are rate-limited per IP (default 10/min); here the limit is set to 3 to keep the test fast. */
import { api, createTestApp, TestApp } from './helpers';
import { resetEnvCache } from '../src/config/env';

describe('rate limiting on auth routes', () => {
  let t: TestApp;
  beforeAll(async () => {
    process.env.AUTH_RATE_LIMIT_PER_MIN = '3';
    resetEnvCache();
    t = await createTestApp();
  });
  afterAll(async () => {
    await t.close();
    process.env.AUTH_RATE_LIMIT_PER_MIN = '10000';
    resetEnvCache();
  });

  it('returns 429 after the limit', async () => {
    const codes: number[] = [];
    for (let i = 0; i < 5; i++) {
      codes.push((await t.http().post(api('/auth/login')).send({ email: 'nobody@example.test', password: 'x' })).status);
    }
    expect(codes.slice(0, 3)).toEqual([401, 401, 401]);
    expect(codes.slice(3)).toEqual([429, 429]);
  });
});
