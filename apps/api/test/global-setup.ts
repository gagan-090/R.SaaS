import { execSync } from 'child_process';
import * as path from 'path';
import { config } from 'dotenv';
import { PrismaClient } from '@prisma/client';
import { testDbUrl } from './test-db';

/** Creates the isolated test database if needed, then applies migrations and the seed (plans, roles, permissions). */
export default async function globalSetup() {
  config({ path: path.resolve(__dirname, '../../../.env.local'), quiet: true });
  const ownerUrl = testDbUrl(process.env.MIGRATION_DATABASE_URL ?? process.env.DATABASE_URL)!;
  const dbName = new URL(ownerUrl).pathname.slice(1);
  const admin = new URL(ownerUrl);
  admin.pathname = '/postgres';
  const pg = new PrismaClient({ datasources: { db: { url: admin.toString() } } });
  try {
    const exists = await pg.$queryRawUnsafe<{ n: number }[]>(`SELECT 1 AS n FROM pg_database WHERE datname = '${dbName.replace(/'/g, '')}'`);
    if (!exists.length) await pg.$executeRawUnsafe(`CREATE DATABASE "${dbName.replace(/"/g, '')}"`);
  } finally {
    await pg.$disconnect();
  }
  const env = { ...process.env, DATABASE_URL: ownerUrl, MIGRATION_DATABASE_URL: ownerUrl };
  execSync('npx prisma migrate deploy', { cwd: path.resolve(__dirname, '..'), env, stdio: 'ignore' });
  execSync('npx ts-node --transpile-only prisma/seed.ts', { cwd: path.resolve(__dirname, '..'), env, stdio: 'ignore' });
}
