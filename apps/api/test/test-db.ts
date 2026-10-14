/**
 * Tests never touch the dev or production database. They use TEST_DATABASE_URL / TEST_MIGRATION_DATABASE_URL when set,
 * else "<db>_test" next to the configured database. Either way the host must be this machine (localhost) — tests
 * create and change data, so a remote database (Neon, RDS…) is refused unless ALLOW_REMOTE_TEST_DB=1.
 */
export function testDbUrl(url: string | undefined, kind: 'app' | 'owner' = 'app'): string | undefined {
  const override = kind === 'owner' ? process.env.TEST_MIGRATION_DATABASE_URL : process.env.TEST_DATABASE_URL;
  const chosen = override ?? url;
  if (!chosen) return chosen;
  const u = new URL(chosen);
  if (!override) {
    const db = u.pathname.replace(/^\//, '');
    if (!db.endsWith('_test')) u.pathname = `/${db}_test`;
  }
  if (!['localhost', '127.0.0.1', '::1'].includes(u.hostname) && process.env.ALLOW_REMOTE_TEST_DB !== '1') {
    throw new Error(
      `Refusing to run tests against ${u.hostname}: tests create data. Set TEST_DATABASE_URL and TEST_MIGRATION_DATABASE_URL ` +
        'to a local Postgres (see .env.example), or ALLOW_REMOTE_TEST_DB=1 if you really mean it.',
    );
  }
  return u.toString();
}
