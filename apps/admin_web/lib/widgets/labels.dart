import '../screens/plans_screen.dart' show featureGroups;

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
};

String auditActionLabel(Object? action) => _actions['$action'] ?? titleCase('$action'.split('.').last.replaceAll('_', ' '));

/// "Demo Owner (Owner)", "Super Admin (Platform admin)", "System" …
String auditActor(Map<String, dynamic> e) {
  final name = e['actorName'] as String?;
  if (name != null) {
    final role = e['actorRole'] == 'Platform admin' ? 'Platform admin' : roleWord(e['actorRole']);
    return role.isEmpty ? name : '$name ($role)';
  }
  return switch (e['actorType']) { 'device' => 'A device', 'admin' => 'A platform admin', 'user' => 'A staff member', _ => 'System' };
}
