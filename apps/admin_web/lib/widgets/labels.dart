import '../screens/plans_screen.dart' show featureGroups;
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart' show HPTone;

/// Words people read instead of system codes ("premium" → "Premium", "auth.login" → "Signed in").

String titleCase(String s) => s.isEmpty ? s : s.split(RegExp(r'[_\s]+')).map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

String statusLabel(Object? s) => switch ('$s') {
      'active' => 'Active',
      'pending' => 'Awaiting verification',
      'suspended' => 'Suspended',
      'blocked' => 'Blocked',
      'grace' => 'In grace period',
      'read_only' => 'Read-only (expired)',
      'not_started' => 'Not started yet',
      'tenant_blocked' => 'Restaurant blocked',
      'revoked' => 'Revoked',
      'superseded' => 'Replaced',
      'none' || 'null' || '' => 'No license',
      final x => titleCase(x),
    };

/// A restaurant that is "active" but has no plan cannot do anything; say so instead of a green "Active".
String restaurantStatusLabel(Object? status, {required bool hasPlan}) => status == 'active' && !hasPlan ? 'Active · no plan' : statusLabel(status);

HPTone restaurantStatusTone(Object? status, {required bool hasPlan}) => status == 'active' && !hasPlan
    ? HPTone.saffron
    : switch ('$status') {
        'active' => HPTone.success,
        'pending' => HPTone.pending,
        'suspended' => HPTone.saffron,
        'blocked' => HPTone.danger,
        _ => HPTone.neutral,
      };

String featureLabel(String flag) {
  for (final (_, items) in featureGroups) {
    for (final (k, l) in items) {
      if (k == flag) return l;
    }
  }
  return titleCase(flag.replaceAll('.', ' '));
}

String roleWord(Object? role) => switch ('$role') {
      'owner' => 'Owner',
      'cashier' => 'Cashier',
      'waiter' => 'Waiter',
      'chef' => 'Chef',
      'it_admin' => 'IT admin',
      'auditor' => 'Auditor',
      'null' || '' => '',
      final x => titleCase(x),
    };

const _platformPermissions = {
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

/// "platform.restaurant.read" → "See restaurants" (role pickers show what a role can do, not permission codes).
String permissionLabel(Object? code) => _platformPermissions['$code'] ?? titleCase('$code'.split('.').skip(1).join(' '));

const _actions = {
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

const _verbs = {'created': 'added', 'updated': 'changed', 'deleted': 'deleted', 'removed': 'removed', 'voided': 'cancelled', 'set': 'set', 'changed': 'changed'};

/// "expense.created" → "Expense added", "inventory.product_updated" → "Product changed": never a raw code.
String auditActionLabel(Object? action) {
  final a = '$action';
  final known = _actions[a];
  if (known != null) return known;
  final parts = a.split('.');
  final words = parts.last.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return 'Activity';
  final verb = words.length > 1 || parts.length > 1 ? words.last : '';
  final subject = words.length > 1 ? words.sublist(0, words.length - 1).join(' ') : (parts.length > 1 ? parts[parts.length - 2].replaceAll('_', ' ') : words.single);
  final text = verb.isEmpty ? subject : '$subject ${_verbs[verb] ?? verb}';
  return '${text[0].toUpperCase()}${text.substring(1)}';
}

String _shortValue(Object? v) {
  if (v == null) return '—';
  // lists of records (roles, dish sizes): their names, e.g. "Onboarding Admin, Platform Auditor"
  if (v is List) return v.isEmpty ? 'none' : _shortValue(v.map((x) => x is Map ? (x['name'] ?? x['code'] ?? x) : x).join(', '));
  if (v is bool) return v ? 'Yes' : 'No';
  final s = v is String ? v : '$v';
  return s.length > 60 ? '${s.substring(0, 57)}…' : s;
}

/// Field-by-field changes of an audit event ("Status: active → suspended"); for creations just the new values.
/// Internal ids and secrets are never shown. Never throws: one malformed record must not blank a whole log.
List<(String, String)> auditChanges(Map<String, dynamic> e) {
  try {
    // before/after are free-form JSON: anything that is not an object (list, text, number) shows as one value
    Map<String, dynamic> asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : v == null ? const {} : {e['action'] == 'platform.admin.roles_changed' ? 'roles' : 'value': v};
    final before = asMap(e['before']);
    final after = asMap(e['after']);
    const hidden = {'id', 'tenantId', 'branchId', 'seq', 'createdAt', 'updatedAt', 'signedToken', 'passwordHash', 'pinHash', 'tokenHash', 'deleted', 'idempotencyKey'};
    bool isId(String k) => hidden.contains(k) || (k.endsWith('Id') && k.length > 2);
    final keys = {...before.keys, ...after.keys}.where((k) => !isId(k)).toList();
    return [
      for (final k in keys)
        if ('${before[k]}' != '${after[k]}' || before.isEmpty)
          (titleCase(k.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}').toLowerCase()),
              before.isEmpty || !before.containsKey(k) ? _shortValue(after[k]) : '${_shortValue(before[k])} → ${_shortValue(after[k])}'),
    ];
  } catch (_) {
    return const [];
  }
}

/// "Demo Owner (Owner)", "Super Admin (Platform admin)", "System" …
String auditActor(Map<String, dynamic> e) {
  final name = e['actorName'] as String?;
  if (name != null) {
    final role = e['actorRole'] == 'Platform admin' ? 'Platform admin' : roleWord(e['actorRole']);
    return role.isEmpty ? name : '$name ($role)';
  }
  return switch (e['actorType']) { 'device' => 'A device', 'admin' => 'A platform admin', 'user' => 'A staff member', _ => 'System' };
}
