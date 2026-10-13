import 'package:flutter/material.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';

/// Phones and small tablets get single-column layouts below this width.
const narrowBreakpoint = 720.0;
bool isNarrow(BuildContext c) => MediaQuery.sizeOf(c).width < narrowBreakpoint;

/// Short message at the bottom. A new message replaces the current one, so staff never read a stale toast.
void toast(BuildContext c, String msg, {bool error = false}) {
  final p = c.hp;
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        Icon(error ? Icons.error_outline_rounded : Icons.check_circle_rounded, color: error ? HPColors.onChili : (p.isDark ? p.success : p.ground), size: 20),
        const SizedBox(width: HPSpace.sm),
        Expanded(child: Text(msg, style: HPType.label(error ? HPColors.onChili : (p.isDark ? p.text : p.ground)))),
      ]),
      backgroundColor: error ? p.danger : null,
      duration: Duration(seconds: error ? 4 : 2),
      // tablets / PCs: a compact pill in the middle, clear of the order panel's buttons on the right
      width: MediaQuery.sizeOf(c).width >= narrowBreakpoint ? 420 : null,
    ));
}

String errText(Object e) => e is HubApiException ? e.message : '$e';

int minutesSince(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}');
  return t == null ? 0 : DateTime.now().toUtc().difference(t.toUtc()).inMinutes.clamp(0, 9999);
}

/// "7:42 PM" (STYLE.md §10: 12-hour clock).
String clock12(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (t == null) return '';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

String rupees(int paise) => formatPaise(paise).replaceAll('.00', '');

const roleNames = {'owner': 'Owner', 'cashier': 'Cashier', 'waiter': 'Waiter', 'chef': 'Chef', 'it_admin': 'IT admin', 'auditor': 'Auditor'};
String roleLabel(List<dynamic> roles) => roles.map((r) => roleNames['$r'] ?? '$r').join(' · ');

/// Accent colour per role for avatars, so staff find themselves quickly on the login screen.
Color roleColor(BuildContext c, String? role) => switch (role) {
      'owner' => c.hp.pending,
      'cashier' => HPColors.saffron,
      'waiter' => c.hp.success,
      'chef' => c.hp.danger,
      _ => c.hp.muted,
    };
