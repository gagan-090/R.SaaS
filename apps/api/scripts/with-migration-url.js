#!/usr/bin/env node
// Runs a command with DATABASE_URL pointed at the owner role (MIGRATION_DATABASE_URL).
// Loads <repo>/.env.local for local dev without overriding variables already set (CI sets them directly).
const path = require('path');
const { spawnSync } = require('child_process');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env.local'), quiet: true });
const url = process.env.MIGRATION_DATABASE_URL;
if (!url) {
  console.error('MIGRATION_DATABASE_URL is not set (run infra/scripts/gen-dev-secrets.sh)');
  process.exit(1);
}
const [cmd, ...args] = process.argv.slice(2);
const r = spawnSync(cmd, args, { stdio: 'inherit', shell: process.platform === 'win32', env: { ...process.env, DATABASE_URL: url } });
process.exit(r.status ?? 1);
