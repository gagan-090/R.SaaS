/** Contract generation exercises every route with throwaway data: always against the isolated "<db>_test" database. */
import * as path from 'path';
import { config } from 'dotenv';
import { testDbUrl } from '../test/test-db';

config({ path: path.resolve(__dirname, '../../../.env.local'), quiet: true });
process.env.DATABASE_URL = testDbUrl(process.env.DATABASE_URL);
process.env.MIGRATION_DATABASE_URL = testDbUrl(process.env.MIGRATION_DATABASE_URL);
process.env.AUTH_RATE_LIMIT_PER_MIN ??= '10000';
process.env.API_RATE_LIMIT_PER_MIN ??= '100000';
