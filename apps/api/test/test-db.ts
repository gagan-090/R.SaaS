/** Tests never touch the dev database: they use "<db>_test" next to it (created, migrated and seeded on demand). */
export function testDbUrl(url: string | undefined): string | undefined {
  if (!url) return url;
  const u = new URL(url);
  const db = u.pathname.replace(/^\//, '');
  if (!db.endsWith('_test')) u.pathname = `/${db}_test`;
  return u.toString();
}
