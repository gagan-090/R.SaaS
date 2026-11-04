/** Words people read instead of system codes ("premium" → "Premium", "auth.login" → "Signed in"). Port of widgets/labels.dart. */

export type Tone = 'neutral' | 'saffron' | 'success' | 'danger' | 'pending';

export const titleCase = (s: string) =>
  !s ? s : s.split(/[_\s]+/).map((w) => (w ? w[0].toUpperCase() + w.substring(1) : w)).join(' ');

/** Feature flags a plan can include (apps/api/src/common/permissions.ts FEATURE_FLAGS), grouped for the editor. */
export const featureGroups: [string, [string, string][]][] = [
  ['Essentials', [
    ['tables', 'Tables & table status'], ['orders.dinein', 'Dine-in orders'], ['orders.takeaway', 'Takeaway orders'],
    ['menu', 'Menu, categories, tax'], ['billing', 'Bills, GST, tips, payments'], ['offline.single', 'Works offline on one device'],
  ]],
  ['Growing restaurant', [
    ['floors', 'Multiple floors'], ['multi_cashier', 'More than one cashier'], ['waiter_app', 'Waiter app on Android'],
    ['lan_hub', 'Pair devices over Wi-Fi'],
  ]],
  ['Premium', [
    ['franchise', 'Multiple branches'], ['roles.extended', 'Chef, IT admin, auditor roles'], ['kds', 'Kitchen display'],
    ['recipes', 'Recipes'], ['menu.approval', 'Chef approval of menu changes'], ['inventory', 'Inventory'], ['shifts', 'Shifts & attendance'],
    ['branding', 'Custom branding (logo, colour, text style)'],
  ]],
  ['Web portal & management', [
    ['staff_portal', 'Staff web portal (email + PIN)'],
    ['roles.custom', 'Custom employee roles'],
    ['floor.editor', 'Visual floor editor (drag tables & chairs)'],
    ['import.excel', 'Excel import (menu & inventory)'],
    ['expenses', 'Expenses & expense logs'],
  ]],
];

export const limitKeys: [string, string][] = [
  ['branches', 'Branches'], ['floorsPerBranch', 'Floors per branch'], ['devicesPerBranch', 'Devices per branch'],
  ['concurrentCashiers', 'Cashiers at once'], ['staffPerBranch', 'Staff per branch'],
];

export function statusLabel(s: unknown): string {
  const v = `${s ?? 'null'}`;
  switch (v) {
    case 'active': return 'Active';
    case 'pending': return 'Awaiting verification';
    case 'suspended': return 'Suspended';
    case 'blocked': return 'Blocked';
    case 'grace': return 'In grace period';
    case 'read_only': return 'Read-only (expired)';
    case 'not_started': return 'Not started yet';
    case 'tenant_blocked': return 'Restaurant blocked';
    case 'revoked': return 'Revoked';
    case 'superseded': return 'Replaced';
    case 'none': case 'null': case '': return 'No license';
    default: return titleCase(v);
  }
}

/** A restaurant that is "active" but has no plan cannot do anything; say so instead of a green "Active". */
export const restaurantStatusLabel = (status: unknown, hasPlan: boolean) => (status === 'active' && !hasPlan ? 'Active · no plan' : statusLabel(status));

export function restaurantStatusTone(status: unknown, hasPlan: boolean): Tone {
  if (status === 'active' && !hasPlan) return 'saffron';
  switch (`${status}`) {
    case 'active': return 'success';
    case 'pending': return 'pending';
    case 'suspended': return 'saffron';
    case 'blocked': return 'danger';
    default: return 'neutral';
  }
}

export function toneForStatus(s: unknown): Tone {
  switch (`${s}`) {
    case 'active': return 'success';
    case 'pending': case 'invited': return 'pending';
    case 'suspended': case 'grace': return 'saffron';
    case 'blocked': case 'disabled': case 'read_only': case 'tenant_blocked': case 'revoked': return 'danger';
    default: return 'neutral';
  }
}

export function featureLabel(flag: string): string {
  for (const [, items] of featureGroups) for (const [k, l] of items) if (k === flag) return l;
  return titleCase(flag.replace(/\./g, ' '));
}

export function roleWord(role: unknown): string {
  const v = `${role ?? 'null'}`;
  switch (v) {
    case 'owner': return 'Owner';
    case 'cashier': return 'Cashier';
    case 'waiter': return 'Waiter';
    case 'chef': return 'Chef';
    case 'it_admin': return 'IT admin';
    case 'auditor': return 'Auditor';
    case 'null': case '': return '';
    default: return titleCase(v);
  }
}

/** Admin account statuses in words ("disabled" reads "deactivated"). */
export const statusWord = (s: unknown) => (`${s}` === 'disabled' ? 'deactivated' : `${s}`);

const platformPermissions: Record<string, string> = {
  'platform.admin.read': 'See admins',
  'platform.admin.invite': 'Add admins',
  'platform.admin.roles': 'Change admin roles',
  'platform.admin.deactivate': 'Deactivate admins',
  'platform.mfa.reset': 'Reset two-step verification',
  'platform.audit.read': 'Read the audit log',
  'platform.restaurant.read': 'See restaurants',
  'platform.restaurant.create': 'Register restaurants',
  'platform.restaurant.update': 'Edit restaurants',
  'platform.restaurant.status': 'Suspend / block restaurants',
  'platform.license.manage': 'Manage licenses',
  'platform.payment.record': 'Record payments',
  'platform.plan.manage': 'Manage plans',
};

/** "platform.restaurant.read" → "See restaurants" (role pickers show what a role can do, not permission codes). */
export const permissionLabel = (code: unknown) => platformPermissions[`${code}`] ?? titleCase(`${code}`.split('.').slice(1).join(' '));

const actions: Record<string, string> = {
  'auth.login': 'Signed in',
  'auth.login_failed': 'Failed sign-in',
  'auth.logout': 'Signed out',
  'auth.mfa_failed': 'Wrong two-step code',
  'auth.refresh_reuse_detected': 'Session reuse blocked',
  'auth.step_up': 'Re-verified identity',
  'mfa.enrolled': 'Set up two-step verification',
  'restaurant.registered': 'Restaurant registered',
  'restaurant.created': 'Restaurant activated by owner',
  'restaurant.updated': 'Restaurant details changed',
  'restaurant.status_changed': 'Restaurant status changed',
  'restaurant.verification_resent': 'Activation email re-sent',
  'restaurant.registration_cancelled': 'Registration cancelled',
  'license.changed': 'License changed',
  'payment.recorded': 'Subscription payment recorded',
  'plan.created': 'Plan added',
  'plan.updated': 'Plan changed',
  'device.hub_registered': 'Hub registered',
  'device.revoked': 'Device revoked',
  'staff.created': 'Staff member added',
  'staff.updated': 'Staff member changed',
  'staff.pin_set': 'Set their own POS PIN',
  'menu.item_created': 'Dish added',
  'menu.item_updated': 'Dish changed',
  'menu.item_deleted': 'Dish deleted',
  'menu.item_photo_set': 'Dish photo uploaded',
  'menu.item_photo_removed': 'Dish photo removed',
  'menu.category_created': 'Category added',
  'menu.category_updated': 'Category renamed',
  'menu.category_deleted': 'Category deleted',
  'floor.created': 'Floor added',
  'floor.updated': 'Floor renamed',
  'floor.deleted': 'Floor deleted',
  'table.created': 'Table added',
  'table.updated': 'Table changed',
  'table.deleted': 'Table deleted',
  'tax_rule.created': 'GST rate added',
  'tenant.profile_updated': 'Restaurant profile changed',
  'platform.admin.invited': 'Admin invited',
  'platform.admin.invite_accepted': 'Admin joined',
  'platform.admin.roles_changed': 'Admin roles changed',
  'platform.admin.deactivated': 'Admin deactivated',
  'platform.admin.mfa_reset': 'Admin two-step reset',
  'platform.role.created': 'Admin role created',
  'platform.admin.created': 'Admin added',
  'platform.admin.activated': 'Admin activated',
  'platform.admin.deleted': 'Admin removed',
  'platform.admin.mfa_policy_changed': 'Admin two-step setting changed',
  'restaurant.activated_by_admin': 'Restaurant activated by House Plating',
  'restaurant.archived': 'Restaurant archived',
  'restaurant.restored': 'Restaurant restored',
  'restaurant.deleted': 'Restaurant deleted',
  'expense.created': 'Expense added',
  'expense.voided': 'Expense cancelled',
  'floor.layout_saved': 'Floor plan saved',
  'import.validated': 'Excel file checked',
  'import.committed': 'Excel import saved',
  'inventory.location_created': 'Storage place added',
  'inventory.location_updated': 'Storage place changed',
  'inventory.movement': 'Stock movement recorded',
  'inventory.movement_retry': 'Stock movement re-sent',
  'inventory.product_created': 'Stock product added',
  'inventory.product_updated': 'Stock product changed',
  'inventory.purchase_received': 'Purchase received',
  'inventory.recipe_updated': 'Recipe changed',
  'inventory.request_created': 'Stock request raised',
  'inventory.request_updated': 'Stock request updated',
  'inventory.supplier_created': 'Supplier added',
  'inventory.supplier_updated': 'Supplier changed',
  'menu.categories_reordered': 'Categories re-ordered',
  'menu.categories_seeded': 'Standard categories added',
  'menu.quick_created': 'Dishes added (quick entry)',
  'menu.variants_updated': 'Dish sizes changed',
  'role.created': 'Custom role added',
  'role.updated': 'Custom role changed',
  'role.deleted': 'Custom role deleted',
  'staff.pin_link_sent': 'PIN link sent',
  'staff.pin_reset_requested': 'PIN reset requested',
  'staff.pin_set_via_link': 'PIN set from email link',
  'staff.unlocked': 'Staff member unlocked',
  'table.status_changed': 'Table status changed',
  'table.reservation_created': 'Table reserved',
  'table.reservation_cancelled': 'Reservation cancelled',
  'tenant.branding_updated': 'Look & colours changed',
  'tenant.logo_set': 'Logo uploaded',
  'tenant.logo_removed': 'Logo removed',
};

const verbs: Record<string, string> = { created: 'added', updated: 'changed', deleted: 'deleted', removed: 'removed', voided: 'cancelled', set: 'set', changed: 'changed' };

/** "expense.created" → "Expense added", "inventory.product_updated" → "Product changed": never a raw code. */
export function auditActionLabel(action: unknown): string {
  const a = `${action}`;
  const known = actions[a];
  if (known) return known;
  const parts = a.split('.');
  const words = parts[parts.length - 1].split('_').filter(Boolean);
  if (words.length === 0) return 'Activity';
  const verb = words.length > 1 || parts.length > 1 ? words[words.length - 1] : '';
  const subject = words.length > 1 ? words.slice(0, -1).join(' ') : parts.length > 1 ? parts[parts.length - 2].replace(/_/g, ' ') : words[0];
  const text = verb === '' ? subject : `${subject} ${verbs[verb] ?? verb}`;
  return text[0].toUpperCase() + text.substring(1);
}

function shortValue(v: unknown): string {
  if (v == null) return '—';
  // lists of records (roles, dish sizes): their names, e.g. "Onboarding Admin, Platform Auditor"
  if (Array.isArray(v)) {
    if (v.length === 0) return 'none';
    return shortValue(v.map((x) => (x && typeof x === 'object' ? (x as Record<string, unknown>).name ?? (x as Record<string, unknown>).code ?? JSON.stringify(x) : x)).join(', '));
  }
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  const s = typeof v === 'string' ? v : typeof v === 'object' ? JSON.stringify(v) : `${v}`;
  return s.length > 60 ? `${s.substring(0, 57)}…` : s;
}

const hidden = new Set(['id', 'tenantId', 'branchId', 'seq', 'createdAt', 'updatedAt', 'signedToken', 'passwordHash', 'pinHash', 'tokenHash', 'deleted', 'idempotencyKey']);
const asText = (v: unknown) => (v == null ? 'null' : typeof v === 'object' ? JSON.stringify(v) : `${v}`);

/**
 * Field-by-field changes of an audit event ("Status: active → suspended"); for creations just the new values.
 * Internal ids and secrets are never shown. Never throws: one malformed record must not blank a whole log.
 */
export function auditChanges(e: Record<string, unknown>): [string, string][] {
  try {
    const asMap = (v: unknown): Record<string, unknown> =>
      v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : v == null ? {} : { [e.action === 'platform.admin.roles_changed' ? 'roles' : 'value']: v };
    const before = asMap(e.before);
    const after = asMap(e.after);
    const isId = (k: string) => hidden.has(k) || (k.endsWith('Id') && k.length > 2);
    const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((k) => !isId(k));
    const empty = Object.keys(before).length === 0;
    const out: [string, string][] = [];
    for (const k of keys) {
      if (asText(before[k]) !== asText(after[k]) || empty) {
        const label = titleCase(k.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase());
        out.push([label, empty || !(k in before) ? shortValue(after[k]) : `${shortValue(before[k])} → ${shortValue(after[k])}`]);
      }
    }
    return out;
  } catch {
    return [];
  }
}

/** "Demo Owner (Owner)", "Super Admin (Platform admin)", "System" … */
export function auditActor(e: Record<string, unknown>): string {
  const name = e.actorName as string | undefined;
  if (name != null) {
    const role = e.actorRole === 'Platform admin' ? 'Platform admin' : roleWord(e.actorRole);
    return role === '' ? name : `${name} (${role})`;
  }
  switch (e.actorType) {
    case 'device': return 'A device';
    case 'admin': return 'A platform admin';
    case 'user': return 'A staff member';
    default: return 'System';
  }
}
