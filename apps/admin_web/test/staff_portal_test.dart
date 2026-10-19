import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_admin_web/util/download.dart';
import 'package:rsaas_admin_web/util/pin_policy.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

/// Employee web portal: email + PIN sign-in, the emailed set-PIN link, and a home showing only what the role allows.
class FakePortalApi {
  final calls = <http.Request>[];
  String? correctPin = '482913';
  Map<String, dynamic> me = {
    'type': 'user', 'id': 'u-chef', 'email': 'kunal@demo.com', 'name': 'Kunal Rao', 'tenantId': 't1', 'roles': ['chef'],
    'permissions': ['menu.read', 'kds.read', 'inventory.read', 'inventory.consume', 'inventory.request', 'order.read'], 'customRoleName': null,
  };

  http.Client client() => MockClient((req) async {
        calls.add(req);
        final path = req.url.path.replaceFirst('/api/v1', '');
        final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
        (int, Object?) r = switch ((req.method, path)) {
          ('POST', '/auth/pin-login') => body['pin'] == correctPin
              ? (200, {'status': 'ok', 'accessToken': 'a', 'refreshToken': 'r', 'expiresIn': 900})
              : (401, {'code': 'invalid_credentials', 'message': 'Invalid email or PIN'}),
          ('POST', '/auth/pin-reset-request') => (202, {'ok': true, 'message': 'If that email belongs to an employee with web access, a link is on its way.'}),
          ('POST', '/auth/pin-link/check') => body['token'] == 'good-token-1234567890'
              ? (200, {'name': 'Kunal Rao', 'email': 'kunal@demo.com', 'restaurantName': 'Demo Dhaba', 'purpose': 'invite'})
              : (400, {'code': 'invalid_link', 'message': 'This link has expired or was already used. Ask the owner for a new one.'}),
          ('POST', '/auth/pin-link/complete') => (200, {'ok': true, 'email': 'kunal@demo.com', 'webAccess': true}),
          ('GET', '/me') => (200, me),
          ('GET', '/records/live-orders') => (200, [
              {'id': 'o1', 'type': 'dine_in', 'status': 'open', 'table': '4', 'waiter': 'Anita', 'openedAt': '2026-10-14T06:00:00Z',
                'lines': [{'name': 'Biryani · Half plate', 'qty': 2, 'status': 'sent', 'notes': 'less spicy'}], 'kitchen': [{'kotNo': 7, 'status': 'preparing'}]},
            ]),
          ('GET', '/inventory/alerts') => (200, {'low': [{'id': 'p1', 'sku': 'RICE-BAS', 'name': 'Basmati rice', 'stock': 2000, 'minStock': 5000, 'unit': 'g'}], 'negative': [], 'expiring': []}),
          ('GET', '/records/sales') => (200, {'summary': {'bills': 3, 'paidBills': 3, 'salesPaise': 123400, 'discountsPaise': 0, 'tipsPaise': 0, 'refundsPaise': 0, 'voids': 0, 'voidsPaise': 0, 'paymentsByMode': {'upi': 100000, 'cash': 23400}}, 'bills': [], 'voids': []}),
          ('GET', '/floors') => (200, [{'id': 'f1', 'name': 'Ground', 'tables': []}]),
          ('GET', '/floors/f1/layout') => (200, {'floor': {'id': 'f1', 'name': 'Ground', 'width': 900, 'height': 500, 'version': 1},
              'tables': [{'id': 't1', 'name': '4', 'seats': 4, 'shape': 'square', 'x': 150, 'y': 150, 'width': 80, 'height': 80, 'rotation': 0, 'chairs': null, 'status': 'available', 'live': 'occupied'}], 'warnings': []}),
          ('GET', '/audit/facets') => (200, {'employees': [{'id': 'u1', 'name': 'Demo Owner', 'role': 'owner'}], 'roles': ['owner', 'cashier'], 'modules': ['Inventory', 'Employees & roles'], 'actions': ['staff.created']}),
          ('GET', '/audit/events') => (200, [
              {'id': 'e1', 'source': 'cloud', 'at': '2026-10-14T06:00:00Z', 'action': 'staff.created', 'module': 'Employees & roles', 'actorName': 'Demo Owner', 'actorRole': 'owner',
                'objectType': 'user', 'objectId': 'u9', 'before': null, 'after': {'name': 'Ravi', 'role': 'cashier'}, 'reason': null, 'requestId': 'req-1'},
              {'id': 'e2', 'source': 'pos', 'at': '2026-10-14T06:05:00Z', 'action': 'pos.order.line_reversed', 'module': 'POS (orders, bills, approvals)', 'actorName': 'Ravi', 'actorRole': 'cashier',
                'objectType': 'order_line', 'objectId': 'l1', 'before': {'status': 'sent'}, 'after': {'status': 'reversed'}, 'reason': 'Guest left', 'requestId': 'ev-2'},
            ]),
          ('GET', '/audit/events.csv') => (200, 'time_utc,source'),
          ('GET', '/audit/imports') => (200, []),
          _ => (404, {'code': 'not_mocked', 'message': '${req.method} $path'}),
        };
        return http.Response.bytes(utf8.encode(jsonEncode(r.$2)), r.$1, headers: {'content-type': 'application/json'});
      });

  Map<String, dynamic> last(String path) => jsonDecode(calls.lastWhere((c) => c.url.path.endsWith(path)).body) as Map<String, dynamic>;
}

Future<FakePortalApi> boot(WidgetTester t, {String? at}) async {
  t.view.physicalSize = const Size(1280, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fake = FakePortalApi();
  final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://x/api/v1', client: fake.client()))]);
  addTearDown(container.dispose);
  if (at != null) container.read(routerProvider).go(at);
  await t.pumpWidget(UncontrolledProviderScope(container: container, child: const AdminApp()));
  await t.pumpAndSettle();
  return fake;
}

void main() {
  test('PIN rules match the server', () {
    expect(pinProblem('12'), 'PIN must be 6 to 8 digits');
    expect(pinProblem('777777'), isNotNull);
    expect(pinProblem('345678'), isNotNull);
    expect(pinProblem('876543'), isNotNull);
    expect(pinProblem('482913'), isNull);
  });

  testWidgets('employee signs in with email + PIN and sees only what a chef may use', (t) async {
    final api = await boot(t);
    await t.tap(find.text('Employee PIN'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-password')), findsNothing);
    await t.enterText(find.byKey(const Key('login-email')), 'kunal@demo.com');
    await t.enterText(find.byKey(const Key('login-pin')), '000000');
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    expect(find.text('Invalid email or PIN'), findsOneWidget);
    await t.enterText(find.byKey(const Key('login-pin')), '482913');
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    expect(api.last('/auth/pin-login'), {'email': 'kunal@demo.com', 'pin': '482913'});
    expect(find.text('Hello, Kunal'), findsOneWidget);
    expect(find.text('Chef'), findsWidgets);
    // no business dashboard, no staff, no settings for a chef
    for (final n in ['Staff', 'Settings', 'Roles', 'Hubs & devices']) {
      expect(find.byKey(Key('nav-$n')), findsNothing, reason: n);
    }
  });

  testWidgets('forgot PIN sends the request and shows the same answer for any email', (t) async {
    final api = await boot(t);
    await t.tap(find.text('Employee PIN'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('forgot-pin')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('reset-email')), 'kunal@demo.com');
    await t.tap(find.byKey(const Key('send-pin-reset')));
    await t.pumpAndSettle();
    expect(api.last('/auth/pin-reset-request'), {'email': 'kunal@demo.com'});
    expect(find.textContaining('If that email belongs to an employee'), findsOneWidget);
  });

  testWidgets('shared employee sign-in link opens email and PIN directly', (t) async {
    await boot(t, at: '/login?mode=employee');
    expect(find.byKey(const Key('login-email')), findsOneWidget);
    expect(find.byKey(const Key('login-pin')), findsOneWidget);
    expect(find.byKey(const Key('login-password')), findsNothing);
  });

  testWidgets('employee link changes an already open password form on a narrow screen', (t) async {
    await boot(t);
    t.view.physicalSize = const Size(348, 740);
    await t.pumpAndSettle();
    final container = ProviderScope.containerOf(t.element(find.byType(AdminApp)));
    expect(find.byKey(const Key('login-password')), findsOneWidget);
    container.read(routerProvider).go('/login?mode=employee');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-pin')), findsOneWidget);
    expect(find.byKey(const Key('login-password')), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('set-PIN link: shows who it is for, checks the rules, then confirms', (t) async {
    final api = await boot(t, at: '/set-pin?token=good-token-1234567890');
    expect(find.text('Kunal Rao · Demo Dhaba'), findsOneWidget);
    await t.enterText(find.byKey(const Key('new-pin')), '123456');
    await t.enterText(find.byKey(const Key('new-pin-again')), '123456');
    await t.tap(find.byKey(const Key('save-pin')));
    await t.pumpAndSettle();
    expect(find.text('PIN cannot be a run of digits like 123456'), findsOneWidget);
    await t.enterText(find.byKey(const Key('new-pin')), '482913');
    await t.enterText(find.byKey(const Key('new-pin-again')), '482914');
    await t.tap(find.byKey(const Key('save-pin')));
    await t.pumpAndSettle();
    expect(find.text('The two PINs do not match'), findsOneWidget);
    await t.enterText(find.byKey(const Key('new-pin-again')), '482913');
    await t.tap(find.byKey(const Key('save-pin')));
    await t.pumpAndSettle();
    expect(api.last('/auth/pin-link/complete'), {'token': 'good-token-1234567890', 'pin': '482913'});
    expect(find.text('Your PIN is set. Sign in with your email and PIN.'), findsOneWidget);
  });

  testWidgets('an expired link says so', (t) async {
    await boot(t, at: '/set-pin?token=old-token-1234567890');
    expect(find.textContaining('expired or was already used'), findsOneWidget);
    expect(find.byKey(const Key('save-pin')), findsNothing);
  });

  Future<FakePortalApi> signInAs(WidgetTester t, String role, List<String> perms) async {
    final api = await boot(t);
    api.me = {...api.me, 'roles': [role], 'permissions': perms, 'name': 'Sam Lee'};
    await t.tap(find.text('Employee PIN'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('login-email')), 'sam@demo.com');
    await t.enterText(find.byKey(const Key('login-pin')), '482913');
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    return api;
  }

  testWidgets('chef home: kitchen orders and low stock; no floor editing, no money', (t) async {
    await signInAs(t, 'chef', ['menu.read', 'kds.read', 'kds.update', 'inventory.read', 'inventory.consume', 'inventory.request', 'order.read']);
    expect(find.text('KITCHEN ORDERS'), findsOneWidget);
    expect(find.text('2 × Biryani · Half plate — less spicy'), findsOneWidget);
    expect(find.textContaining('KOT 7 preparing'), findsOneWidget);
    expect(find.byKey(const Key('home-low-RICE-BAS')), findsOneWidget);
    expect(find.byKey(const Key('go-inventory')), findsOneWidget);
    expect(find.byKey(const Key('today-sales')), findsNothing);
    expect(find.text('TABLES'), findsNothing);
  });

  testWidgets('cashier home: today\'s bills and payments by method, open orders; the POS note', (t) async {
    await signInAs(t, 'cashier', ['floor.read', 'menu.read', 'order.read', 'order.write', 'payment.take', 'kds.read', 'clock', 'reports.own']);
    expect(find.byKey(const Key('pos-note')), findsOneWidget);
    expect(find.byKey(const Key('today-sales')), findsOneWidget);
    expect(find.text('UPI'), findsOneWidget);
    expect(find.text('OPEN ORDERS'), findsOneWidget);
  });

  testWidgets('waiter home: the live floor plan with table states; no sales figures', (t) async {
    await signInAs(t, 'waiter', ['floor.read', 'menu.read', 'order.read', 'order.write', 'order.transfer', 'order.reverse', 'kds.read', 'clock', 'reports.own']);
    expect(find.text('TABLES'), findsOneWidget);
    expect(find.byKey(const Key('table-4')), findsOneWidget);
    expect(find.text('Occupied'), findsWidgets);
    expect(find.byKey(const Key('today-sales')), findsNothing);
  });

  testWidgets('auditor: audit log with POS actions, before/after, filters and CSV export; no edit buttons anywhere', (t) async {
    final api = await signInAs(t, 'auditor', ['restaurant.profile.read', 'license.read', 'staff.read', 'floor.read', 'menu.read', 'order.read', 'kds.read', 'audit.read', 'audit.export']);
    await t.tap(find.byKey(const Key('nav-Audit & records')));
    await t.pumpAndSettle();
    // readable words, never raw action codes or JSON
    expect(find.text('Staff member added'), findsOneWidget);
    expect(find.text('staff.created'), findsNothing);
    expect(find.text('Line reversed'), findsOneWidget);
    await t.tap(find.text('Line reversed'));
    await t.pumpAndSettle();
    expect(find.text('sent → reversed'), findsOneWidget);
    expect(find.textContaining('"status"'), findsNothing);
    await t.enterText(find.byKey(const Key('f-q')), 'req-1');
    await t.tap(find.byKey(const Key('f-apply')));
    await t.pumpAndSettle();
    expect(api.calls.last.url.queryParameters['q'], 'req-1');
    await t.tap(find.byKey(const Key('export-log')));
    await t.pumpAndSettle();
    expect(lastSavedFile?.name, 'audit-log.csv');
    expect(find.byType(DangerButton), findsNothing);
  });
}
