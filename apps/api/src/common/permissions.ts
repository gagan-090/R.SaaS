/**
 * Single source of truth for permission keys, restaurant role grants and plan feature flags.
 * docs/PERMISSIONS.md is generated from this file (pnpm --filter @rsaas/api exec ts-node scripts/gen-permissions-doc.ts).
 */

export const PLATFORM_PERMISSIONS = {
  'platform.restaurant.read': 'View restaurants, their licenses, devices and payments',
  'platform.restaurant.create': 'Register a restaurant (sends owner verification email)',
  'platform.restaurant.update': 'Edit restaurant profile fields',
  'platform.restaurant.status': 'Activate, suspend, block or reactivate a restaurant (with reason)',
  'platform.license.manage': 'Issue, renew, upgrade, downgrade or revoke licenses',
  'platform.payment.record': 'Record a subscription payment',
  'platform.plan.manage': 'Create and edit subscription plans',
  'platform.admin.read': 'List platform admins and roles',
  'platform.admin.invite': 'Invite platform admins',
  'platform.admin.roles': 'Assign roles to platform admins / create roles',
  'platform.admin.deactivate': 'Deactivate a platform admin',
  'platform.mfa.reset': "Reset another admin's MFA (requires step-up)",
  'platform.audit.read': 'Read the platform audit log',
} as const;

export const RESTAURANT_PERMISSIONS = {
  'restaurant.profile.read': 'View restaurant profile and tax settings',
  'restaurant.profile.manage': 'Edit restaurant profile and tax settings',
  'license.read': 'View own license and plan',
  'staff.read': 'View staff users and roles',
  'staff.manage': 'Manage staff users and roles',
  'device.manage': 'Pair devices, set hub, technical settings',
  'floor.read': 'View floors and tables',
  'floor.manage': 'Manage floors and tables',
  'menu.read': 'View menu, categories and tax rules',
  'menu.submit': 'Submit menu item / ingredient change',
  'menu.approve': 'Approve recipe and ingredient changes',
  'menu.publish': 'Publish menu changes and prices; manage menu master data',
  'order.read': 'View orders',
  'order.write': 'Create / edit orders',
  'order.transfer': 'Transfer an order to another table',
  'order.reverse': 'Reverse an item not yet sent to kitchen',
  'order.reverse.sent': 'Reverse an item already sent to kitchen (or approve with PIN)',
  'discount.apply': 'Apply a discount',
  'payment.take': 'Take payment, close bill, assign tip',
  'bill.adjust': 'Post an adjustment to a paid bill (or approve with PIN)',
  'kds.read': 'View kitchen queue',
  'kds.update': 'Kitchen queue: accept / preparing / ready / served',
  'recipe.read': 'View recipes',
  'recipe.write': 'Create and version recipes',
  'inventory.read': 'View stock, products and movement history',
  'inventory.manage': 'Inventory products, suppliers, locations and recipe mapping',
  'inventory.write': 'Opening stock, purchases/receipts, returns, stock counts, adjustments, transfers',
  'inventory.consume': 'Record kitchen consumption and wastage',
  'inventory.request': 'Request replenishment',
  'expense.read': 'View purchases and expenses',
  'expense.write': 'Record expenses',
  'import.run': 'Import menu / inventory from Excel',
  'shift.read': 'View shifts and attendance setup',
  'shift.manage': 'Shifts, breaks, attendance setup',
  'clock': 'Clock in / out, start / end break',
  'reports.read': 'Reports and dashboards (branch-scoped)',
  'reports.own': 'Own shift / own tips reports',
  'audit.read': 'Restaurant audit log',
  'audit.export': 'Export restaurant records and audit log',
  'roles.manage': 'Create and edit custom roles',
} as const;

export type PlatformPermission = keyof typeof PLATFORM_PERMISSIONS;
export type RestaurantPermission = keyof typeof RESTAURANT_PERMISSIONS;
export type PermissionKey = PlatformPermission | RestaurantPermission;

export const ALL_PLATFORM_PERMISSIONS = Object.keys(PLATFORM_PERMISSIONS) as PlatformPermission[];

export type RestaurantRoleName = 'owner' | 'it_admin' | 'cashier' | 'waiter' | 'chef' | 'auditor' | 'custom';

/** Build Specification §03 role matrix. PIN-gated cells (P) are handled by owner PIN approval on the hub. */
export const ROLE_PERMISSIONS: Record<RestaurantRoleName, RestaurantPermission[]> = {
  // Owner: everything in the restaurant (plan features still apply).
  owner: Object.keys(RESTAURANT_PERMISSIONS) as RestaurantPermission[],
  // Restaurant Admin (it_admin in the database): operations, employees, inventory and reporting — no custom roles.
  it_admin: [
    'restaurant.profile.read', 'restaurant.profile.manage', 'license.read', 'staff.read', 'staff.manage',
    'device.manage', 'floor.read', 'floor.manage', 'menu.read', 'menu.submit', 'menu.publish',
    'inventory.read', 'inventory.manage', 'inventory.write', 'inventory.consume', 'inventory.request',
    'expense.read', 'expense.write', 'import.run', 'order.read', 'kds.read',
    'shift.read', 'shift.manage', 'clock', 'reports.read', 'audit.read', 'audit.export',
  ],
  cashier: [
    'floor.read', 'menu.read', 'menu.submit', 'order.read', 'order.write', 'order.transfer', 'order.reverse',
    'payment.take', 'kds.read', 'clock', 'reports.own',
  ],
  waiter: ['floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'kds.read', 'clock', 'reports.own'],
  // Chef: view stock, record kitchen consumption and wastage, request replenishment — no receipts or adjustments.
  chef: [
    'menu.read', 'menu.approve', 'kds.read', 'kds.update', 'recipe.read', 'recipe.write',
    'inventory.read', 'inventory.consume', 'inventory.request', 'order.read', 'clock',
  ],
  // Auditor: read-only everything, plus exports. Never a mutation permission.
  auditor: [
    'restaurant.profile.read', 'license.read', 'staff.read', 'floor.read', 'menu.read', 'order.read', 'kds.read',
    'recipe.read', 'inventory.read', 'expense.read', 'shift.read', 'reports.read', 'audit.read', 'audit.export',
  ],
  custom: [], // from the custom role
};

/** Permissions that only read (an auditor-style custom role may hold only these). */
export const READ_ONLY_PERMISSIONS: RestaurantPermission[] = (Object.keys(RESTAURANT_PERMISSIONS) as RestaurantPermission[]).filter(
  (p) => p.endsWith('.read') || p === 'audit.export' || p === 'reports.own' || p === 'license.read',
);

/** Permissions a role may receive as `extra_permissions` (the "G" cells). */
export const GRANTABLE_EXTRAS: Partial<Record<RestaurantRoleName, RestaurantPermission[]>> = {
  cashier: ['discount.apply'],
};

/** Build Specification §04. */
export const FEATURE_FLAGS = {
  tables: 'Tables, free/occupied status, table transfer',
  'orders.dinein': 'Dine-in orders',
  'orders.takeaway': 'Takeaway orders',
  menu: 'Categories, items, images, tax per item',
  billing: 'Bills, taxes, discounts, tips, reversals, adjustments, print',
  'offline.single': 'Device runs as its own hub',
  floors: 'Multiple floors, per-floor layout, cross-floor transfer',
  multi_cashier: 'More than one concurrent cashier session',
  waiter_app: 'Waiter role on Android',
  lan_hub: 'Other devices pair to the hub over Wi-Fi',
  franchise: 'Multiple branches, consolidated dashboard and invoice',
  'roles.extended': 'IT Admin, Chef, Auditor roles; branch-scoped RBAC',
  kds: 'Kitchen Display System',
  recipes: 'Recipe versions',
  'menu.approval': 'Chef approval workflow',
  inventory: 'Departments, stock, receipts, transfers, wastage, consumption',
  shifts: 'Shift templates, breaks, attendance',
  branding: "Restaurant's own colour, logo and text style on the console, POS and bills",
  staff_portal: 'Employees sign in to the web portal with email + PIN',
  'roles.custom': 'Owner-defined roles with chosen permissions',
  'floor.editor': 'Visual floor layout editor (table shapes, chairs, positions)',
  'import.excel': 'Excel import of menu and inventory',
  expenses: 'Purchases and expense records',
} as const;
export type FeatureFlag = keyof typeof FEATURE_FLAGS;

const STANDARD: FeatureFlag[] = ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single'];
const PROFESSIONAL: FeatureFlag[] = [...STANDARD, 'floors', 'multi_cashier', 'waiter_app', 'lan_hub'];
const PREMIUM: FeatureFlag[] = [
  ...PROFESSIONAL, 'franchise', 'roles.extended', 'kds', 'recipes', 'menu.approval', 'inventory', 'shifts', 'branding',
  'staff_portal', 'roles.custom', 'floor.editor', 'import.excel', 'expenses',
];

/** Seeded plans. Prices are placeholders until the client supplies them (Chef's Defaults). */
export const PLAN_DEFAULTS = [
  { code: 'standard', name: 'Standard', featureFlags: STANDARD, pricePaise: 0,
    limits: { branches: 1, floorsPerBranch: 1, devicesPerBranch: 1, concurrentCashiers: 1, staffPerBranch: null } },
  { code: 'professional', name: 'Professional', featureFlags: PROFESSIONAL, pricePaise: 0,
    limits: { branches: 1, floorsPerBranch: null, devicesPerBranch: null, concurrentCashiers: null, staffPerBranch: null } },
  { code: 'premium', name: 'Premium', featureFlags: PREMIUM, pricePaise: 0,
    limits: { branches: null, floorsPerBranch: null, devicesPerBranch: null, concurrentCashiers: null, staffPerBranch: null } },
] as const;

/** Roles that need the roles.extended flag (Premium). */
export const EXTENDED_ROLES: RestaurantRoleName[] = ['it_admin', 'chef', 'auditor'];

/** Which plan feature a permission needs (no entry = always available). A permission whose feature is missing is
 * dropped from every actor, so a downgrade never needs data changes: owners keep their account and data stay. */
export const PERMISSION_FEATURE: Partial<Record<RestaurantPermission, FeatureFlag>> = {
  'inventory.read': 'inventory', 'inventory.manage': 'inventory', 'inventory.write': 'inventory',
  'inventory.consume': 'inventory', 'inventory.request': 'inventory',
  'expense.read': 'expenses', 'expense.write': 'expenses', 'import.run': 'import.excel', 'roles.manage': 'roles.custom',
};

/** Drops permissions whose plan feature is not in the license (custom-role permissions need "roles.custom"). */
export function limitToPlan(perms: Set<string>, features: string[]): Set<string> {
  return new Set([...perms].filter((p) => {
    const f = PERMISSION_FEATURE[p as RestaurantPermission];
    return !f || features.includes(f);
  }));
}

export function permissionsForRoles(
  assignments: { role: RestaurantRoleName; extraPermissions?: string[]; customPermissions?: string[] }[],
): Set<string> {
  const out = new Set<string>();
  for (const a of assignments) {
    ROLE_PERMISSIONS[a.role].forEach((p) => out.add(p));
    if (a.role === 'custom') (a.customPermissions ?? []).filter((p) => p in RESTAURANT_PERMISSIONS).forEach((p) => out.add(p));
    const allowed = GRANTABLE_EXTRAS[a.role] ?? [];
    (a.extraPermissions ?? []).filter((p) => (allowed as string[]).includes(p)).forEach((p) => out.add(p));
  }
  return out;
}
