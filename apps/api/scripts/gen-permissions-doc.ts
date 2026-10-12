/* Generates docs/PERMISSIONS.md from src/common/permissions.ts so the doc can never drift from the code. */
import * as fs from 'fs';
import * as path from 'path';
import {
  FEATURE_FLAGS, GRANTABLE_EXTRAS, PLAN_DEFAULTS, PLATFORM_PERMISSIONS, RESTAURANT_PERMISSIONS, ROLE_PERMISSIONS, RestaurantRoleName,
} from '../src/common/permissions';

const roles = Object.keys(ROLE_PERMISSIONS) as RestaurantRoleName[];
const L: string[] = [];
L.push('# Permission matrix (role × action × plan)', '');
L.push('> Generated from `apps/api/src/common/permissions.ts` by `pnpm --filter @rsaas/api exec ts-node --transpile-only scripts/gen-permissions-doc.ts`. Do not edit by hand.', '');
L.push('Enforcement: every API route declares `@RequirePermissions(...)` (or is explicitly `@Public`/`@AuthenticatedOnly`); routes without a declaration are refused. Tenant routes also declare `@RequiresFeature(flag)`, checked against the **signed** license token, and writes are refused while the license is read-only (expired past 7-day grace, suspended, blocked or revoked). The hub applies the same keys offline.', '');
L.push('## Platform tier (Super Admin portal)', '', '| Permission | Meaning | Super Admin | Onboarding Admin | Platform Auditor |', '| --- | --- | --- | --- | --- |');
const onboarding = ['platform.restaurant.read', 'platform.restaurant.create', 'platform.restaurant.update', 'platform.restaurant.status', 'platform.license.manage', 'platform.payment.record'];
const pAuditor = ['platform.restaurant.read', 'platform.admin.read', 'platform.audit.read'];
for (const [k, d] of Object.entries(PLATFORM_PERMISSIONS)) {
  L.push(`| \`${k}\` | ${d} | Y | ${onboarding.includes(k) ? 'Y' : '—'} | ${pAuditor.includes(k) ? 'R' : '—'} |`);
}
L.push('', 'Platform roles are data (`platform_roles`); Super Admins can create more. Guards: an admin can only grant permissions they hold, cannot change their own roles, and cannot edit an admin who holds more authority. MFA reset additionally needs a 5-minute step-up token (password + TOTP).', '');
L.push('## Restaurant tier (POS / owner)', '', `| Permission | Meaning | ${roles.join(' | ')} |`, `| --- | --- | ${roles.map(() => '---').join(' | ')} |`);
for (const [k, d] of Object.entries(RESTAURANT_PERMISSIONS)) {
  const cells = roles.map((r) => (ROLE_PERMISSIONS[r] as string[]).includes(k) ? 'Y' : ((GRANTABLE_EXTRAS[r] ?? []) as string[]).includes(k) ? 'G' : '—');
  L.push(`| \`${k}\` | ${d} | ${cells.join(' | ')} |`);
}
L.push('', 'Key: Y = allowed · G = only if granted to that user (`extra_permissions`) · — = refused. Owner/manager **PIN** approval on the hub covers "reverse a sent item" and "adjust a paid bill" for cashiers. In Premium every restaurant role is scoped to `branch_ids` (empty = all branches). Auditor holds read keys only, so every write route returns 403 (tested across all routes).', '');
L.push('## Plans × feature flags', '', `| Flag | Gates | ${PLAN_DEFAULTS.map((p) => p.name).join(' | ')} |`, `| --- | --- | ${PLAN_DEFAULTS.map(() => '---').join(' | ')} |`);
for (const [f, d] of Object.entries(FEATURE_FLAGS)) {
  L.push(`| \`${f}\` | ${d} | ${PLAN_DEFAULTS.map((p) => ((p.featureFlags as readonly string[]).includes(f) ? 'Y' : '—')).join(' | ')} |`);
}
L.push('', '### Limits (configurable per plan; `null` = set by client)', '', `| Limit | ${PLAN_DEFAULTS.map((p) => p.name).join(' | ')} |`, `| --- | ${PLAN_DEFAULTS.map(() => '---').join(' | ')} |`);
for (const k of Object.keys(PLAN_DEFAULTS[0].limits)) {
  L.push(`| ${k} | ${PLAN_DEFAULTS.map((p) => String((p.limits as Record<string, unknown>)[k] ?? 'client')).join(' | ')} |`);
}
fs.writeFileSync(path.resolve(__dirname, '../../../docs/PERMISSIONS.md'), L.join('\n') + '\n');
console.log('wrote docs/PERMISSIONS.md');
