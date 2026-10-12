import * as path from 'path';
import { config } from 'dotenv';

config({ path: path.resolve(__dirname, '../../../.env.local'), quiet: true });
process.env.NODE_ENV = 'test';
// Auth routes are limited to 10/min/IP in production; tests log in many times from one IP.
process.env.AUTH_RATE_LIMIT_PER_MIN ??= '10000';
process.env.API_RATE_LIMIT_PER_MIN ??= '100000';
