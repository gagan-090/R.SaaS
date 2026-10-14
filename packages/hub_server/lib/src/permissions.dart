/// Restaurant role → permission keys. Mirrors apps/api/src/common/permissions.ts (ROLE_PERMISSIONS);
/// the hub enforces these offline. Keep both in sync (test/permissions_test.dart checks the shared keys).
const rolePermissions = <String, Set<String>>{
  'owner': {
    'floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'order.reverse.sent',
    'discount.apply', 'payment.take', 'bill.adjust', 'kds.read', 'device.manage', 'clock', 'reports.read', 'reports.own',
  },
  'it_admin': {'floor.read', 'menu.read', 'device.manage', 'clock', 'reports.read'},
  'cashier': {'floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'payment.take', 'kds.read', 'clock', 'reports.own'},
  'waiter': {'floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'kds.read', 'clock', 'reports.own'},
  'chef': {'menu.read', 'kds.read', 'kds.update', 'clock'},
  'auditor': {'floor.read', 'menu.read', 'order.read', 'kds.read', 'reports.read'},
};

const grantableExtras = <String, Set<String>>{
  'cashier': {'discount.apply'},
};

/// Every permission the hub knows how to enforce. A custom role's permissions are limited to these.
final hubPermissions = {for (final s in rolePermissions.values) ...s};

Set<String> permissionsFor(List<Map<String, Object?>> roles) {
  final out = <String>{};
  for (final r in roles) {
    final role = r['role'] as String;
    out.addAll(rolePermissions[role] ?? const {});
    // owner-defined role: the cloud sends its permissions (only when the plan includes custom roles)
    if (role == 'custom') out.addAll(((r['permissions'] as List?) ?? const []).cast<String>().where(hubPermissions.contains));
    final extras = ((r['extraPermissions'] as List?) ?? const []).cast<String>();
    out.addAll(extras.where((p) => grantableExtras[role]?.contains(p) ?? false));
  }
  return out;
}
