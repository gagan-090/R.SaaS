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
  'inventory.read': 'View inventory',
  'inventory.write': 'Inventory receipts, transfers, adjustments, wastage',
  'shift.read': 'View shifts and attendance setup',
  'shift.manage': 'Shifts, breaks, attendance setup',
  'clock': 'Clock in / out, start / end break',
  'reports.read': 'Reports and dashboards (branch-scoped)',
  'reports.own': 'Own shift / own tips reports',
  'audit.read': 'Restaurant audit log',
} as const;

export type PlatformPermission = keyof typeof PLATFORM_PERMISSIONS;
export type RestaurantPermission = keyof typeof RESTAURANT_PERMISSIONS;
export type PermissionKey = PlatformPermission | RestaurantPermission;

export const ALL_PLATFORM_PERMISSIONS = Object.keys(PLATFORM_PERMISSIONS) as PlatformPermission[];

export type RestaurantRoleName = 'owner' | 'it_admin' | 'cashier' | 'waiter' | 'chef' | 'auditor';

/** Build Specification §03 role matrix. PIN-gated cells (P) are handled by owner PIN approval on the hub. */
export const ROLE_PERMISSIONS: Record<RestaurantRoleName, RestaurantPermission[]> = {
  owner: [
    'restaurant.profile.read', 'restaurant.profile.manage', 'license.read', 'staff.read', 'staff.manage',
    'device.manage', 'floor.read', 'floor.manage', 'menu.read', 'menu.submit', 'menu.approve', 'menu.publish',
    'order.read', 'order.write', 'order.transfer', 'order.reverse', 'order.reverse.sent', 'discount.apply',
    'payment.take', 'bill.adjust', 'kds.read', 'recipe.read', 'inventory.read', 'inventory.write',
    'shift.read', 'shift.manage', 'clock', 'reports.read', 'reports.own', 'audit.read',
  ],
  it_admin: [
    'restaurant.profile.read', 'restaurant.profile.manage', 'license.read', 'staff.read', 'staff.manage',
    'device.manage', 'floor.read', 'floor.manage', 'menu.read', 'menu.submit', 'menu.publish',
    'inventory.read', 'inventory.write', 'shift.read', 'shift.manage', 'clock', 'reports.read', 'audit.read',
  ],
  cashier: [
    'floor.read', 'menu.read', 'menu.submit', 'order.read', 'order.write', 'order.transfer', 'order.reverse',
    'payment.take', 'kds.read', 'clock', 'reports.own',
  ],
  waiter: ['floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'kds.read', 'clock', 'reports.own'],
  chef: ['menu.read', 'menu.approve', 'kds.read', 'kds.update', 'recipe.read', 'recipe.write', 'inventory.read', 'inventory.write', 'clock'],
  auditor: [
    'restaurant.profile.read', 'license.read', 'staff.read', 'floor.read', 'menu.read', 'order.read', 'kds.read',
    'recipe.read', 'inventory.read', 'shift.read', 'reports.read', 'audit.read',
  ],
};

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
} as const;
export type FeatureFlag = keyof typeof FEATURE_FLAGS;

const STANDARD: FeatureFlag[] = ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single'];
const PROFESSIONAL: FeatureFlag[] = [...STANDARD, 'floors', 'multi_cashier', 'waiter_app', 'lan_hub'];
const PREMIUM: FeatureFlag[] = [
  ...PROFESSIONAL, 'franchise', 'roles.extended', 'kds', 'recipes', 'menu.approval', 'inventory', 'shifts',
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

export function permissionsForRoles(
  assignments: { role: RestaurantRoleName; extraPermissions?: string[] }[],
): Set<string> {
  const out = new Set<string>();
  for (const a of assignments) {
    ROLE_PERMISSIONS[a.role].forEach((p) => out.add(p));
    const allowed = GRANTABLE_EXTRAS[a.role] ?? [];
    (a.extraPermissions ?? []).filter((p) => (allowed as string[]).includes(p)).forEach((p) => out.add(p));
  }
  return out;
}
