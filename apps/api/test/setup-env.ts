import * as path from 'path';
import { config } from 'dotenv';
import { testDbUrl } from './test-db';

config({ path: path.resolve(__dirname, '../../../.env.local'), quiet: true });
// isolated "<db>_test" database (see global-setup.ts): test runs never add rows to the dev database
process.env.DATABASE_URL = testDbUrl(process.env.DATABASE_URL);
process.env.MIGRATION_DATABASE_URL = testDbUrl(process.env.MIGRATION_DATABASE_URL, 'owner');
process.env.NODE_ENV = 'test';
// Auth routes are limited to 10/min/IP in production; tests log in many times from one IP.
process.env.AUTH_RATE_LIMIT_PER_MIN ??= '10000';
process.env.API_RATE_LIMIT_PER_MIN ??= '100000';
