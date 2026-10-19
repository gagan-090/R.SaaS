import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

Future<FixtureApi> pumpApp(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fx = FixtureApi();
  await t.pumpWidget(ProviderScope(
    overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))],
    child: const AdminApp(),
  ));
  await t.pumpAndSettle();
  return fx;
}

Future<void> signIn(WidgetTester t) async {
  await t.enterText(find.byKey(const Key('login-email')), 'admin@example.com');
  await t.enterText(find.byKey(const Key('login-password')), 'pw');
  await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('mfa-code')), '123456');
  await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('P1/P2: password then MFA code lands on the dashboard', (t) async {
    final fx = await pumpApp(t);
    expect(find.text('Sign in'), findsWidgets);
    await t.enterText(find.byKey(const Key('login-email')), 'admin@example.com');
    await t.enterText(find.byKey(const Key('login-password')), 'pw');
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    expect(find.text('Two-step verification'), findsOneWidget);
    await t.enterText(find.byKey(const Key('mfa-code')), '123456');
    await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.pumpAndSettle();
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('RECENT ACTIVITY'), findsOneWidget);
    final verify = jsonDecode(fx.where('POST', '/auth/mfa/verify').single.body) as Map;
    expect(verify['code'], '123456');
    expect(verify.containsKey('recoveryCode'), isFalse);
  });

  testWidgets('P1: wrong password shows the server message', (t) async {
    final fx = FixtureApi()..overrides['POST /auth/login'] = (401, {'code': 'invalid_credentials', 'message': 'Invalid email or password'});
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('login-email')), 'a@b.c');
    await t.enterText(find.byKey(const Key('login-password')), 'x');
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    expect(find.text('Invalid email or password'), findsOneWidget);
  });

  testWidgets('P4/P6: list → detail → suspend requires a reason and sends it', (t) async {
    final fx = await pumpApp(t);
    await signIn(t);
    await t.tap(find.text('Restaurants').first);
    await t.pumpAndSettle();
    final first = (FixtureApi.fixture('GET_restaurants.json')! as Map)['items'][0] as Map;
    expect(find.text('${first['name']}'), findsOneWidget);
    await t.tap(find.byKey(const Key('filter-Status')));
    await t.pumpAndSettle();
    await t.tap(find.text('Suspended').last); // filters show words, not codes
    await t.pumpAndSettle();
    expect(fx.where('GET', '/restaurants').last.url.queryParameters['status'], 'suspended');

    await t.tap(find.text('${first['name']}'));
    await t.pumpAndSettle();
    final detail = FixtureApi.fixture('GET_restaurants_id.json')! as Map;
    expect(find.text('${detail['name']}'), findsWidgets);
    // people read words, not system codes
    final features = ((detail['entitlement'] as Map?)?['features'] as List? ?? const []).cast<String>();
    if (features.contains('orders.dinein')) {
      expect(find.text('Dine-in orders'), findsOneWidget);
      expect(find.text('orders.dinein'), findsNothing);
    }
    expect(find.text('${detail['status']}'), findsNothing, reason: 'status shown in Title Case');
    await t.tap(find.text('Suspend'));
    await t.pumpAndSettle();
    await t.tap(find.text('Suspend').last); // confirm without a reason → nothing sent
    await t.pumpAndSettle();
    expect(fx.where('POST', '/status'), isEmpty);
    await t.enterText(find.byKey(const Key('reason-field')), 'Unpaid for 2 months');
    await t.pump();
    await t.tap(find.text('Suspend').last);
    await t.pumpAndSettle();
    final sent = jsonDecode(fx.where('POST', '/status').single.body) as Map;
    expect(sent, {'action': 'suspend', 'reason': 'Unpaid for 2 months'});
  });

  testWidgets('P10: MFA reset asks for a reason, then step-up, and sends the step-up token', (t) async {
    final fx = await pumpApp(t);
    await signIn(t);
    await t.tap(find.text('Admins'));
    await t.pumpAndSettle();
    final admins = (FixtureApi.fixture('GET_platform_admins.json')! as List).cast<Map>();
    final target = admins.firstWhere((a) => a['mfaEnrolled'] == true && a['id'] != (FixtureApi.fixture('GET_me.json')! as Map)['id']);
    await t.tap(find.descendant(of: find.byKey(Key('admin-${target['email']}')), matching: find.byTooltip('Actions')));
    await t.pumpAndSettle();
    await t.tap(find.text('Reset MFA…'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('reason-field')), 'Lost phone, identity checked');
    await t.pump();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(find.text('Confirm it is you'), findsOneWidget);
    await t.enterText(find.byKey(const Key('stepup-password')), 'my-password');
    await t.enterText(find.byKey(const Key('stepup-code')), '654321');
    await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.pumpAndSettle();
    expect(fx.where('POST', '/auth/step-up'), hasLength(1));
    final reset = fx.where('POST', '/mfa/reset').single;
    expect(reset.headers['x-step-up-token'], (FixtureApi.fixture('POST_auth_step_up.json')! as Map)['stepUpToken']);
    expect(jsonDecode(reset.body), {'reason': 'Lost phone, identity checked'});
    expect(find.textContaining('notification sent'), findsOneWidget);
  });

  for (final size in [const Size(1600, 1000), const Size(390, 844)]) {
    testWidgets('Add admin uses only name, email and password at width ${size.width}', (t) async {
      final fx = await pumpApp(t);
      await signIn(t);
      t.view.physicalSize = size;
      final container = ProviderScope.containerOf(t.element(find.byType(AdminApp)));
      container.read(routerProvider).go('/admins');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('add-platform-admin')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('save-platform-admin')));
      await t.pumpAndSettle();
      expect(fx.where('POST', '/platform/admins'), isEmpty);
      expect(find.text('Enter the admin’s name'), findsOneWidget);
      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(find.text('Use at least 12 characters'), findsOneWidget);
      await t.enterText(find.byKey(const Key('new-admin-name')), 'New Admin');
      await t.enterText(find.byKey(const Key('new-admin-email')), 'new@example.test');
      await t.ensureVisible(find.byKey(const Key('new-admin-password')));
      await t.enterText(find.byKey(const Key('new-admin-password')), 'Long-admin-test-password');
      final created = {'id': 'new-id', 'email': 'new@example.test', 'name': 'New Admin', 'status': 'active', 'roles': [{'id': 'r1', 'name': 'Onboarding Admin'}], 'mfaEnrolled': false};
      fx.overrides['POST /platform/admins/create'] = (201, created);
      fx.overrides['GET /platform/admins'] = (200, [created]);
      await t.tap(find.byKey(const Key('save-platform-admin')));
      await t.pumpAndSettle();
      expect(jsonDecode(fx.where('POST', '/platform/admins/create').single.body), {'name': 'New Admin', 'email': 'new@example.test', 'password': 'Long-admin-test-password'});
      expect(find.text('New Admin'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.byKey(const Key('save-platform-admin')), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('an invited admin can be activated with a password using the existing account', (t) async {
    final fx = await pumpApp(t);
    final invited = {'id': 'invited-id', 'name': 'Invited Admin', 'email': 'pending@example.test', 'status': 'invited', 'roles': [{'id': 'r1', 'name': 'Platform Auditor'}], 'mfaEnrolled': false};
    fx.overrides['GET /platform/admins'] = (200, [invited]);
    await signIn(t);
    await t.tap(find.text('Admins'));
    await t.pumpAndSettle();
    await t.tap(find.descendant(of: find.byKey(const Key('admin-pending@example.test')), matching: find.byTooltip('Actions')));
    await t.pumpAndSettle();
    await t.tap(find.text('Set password & activate'));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.descendant(of: find.byKey(const Key('new-admin-email')), matching: find.byType(TextField))).readOnly, isTrue);
    await t.enterText(find.byKey(const Key('new-admin-password')), 'Long-activation-password');
    fx.overrides['POST /platform/admins/invited-id/activate'] = (200, {...invited, 'status': 'active'});
    fx.overrides['GET /platform/admins'] = (200, [{...invited, 'status': 'active'}]);
    await t.tap(find.byKey(const Key('save-platform-admin')));
    await t.pumpAndSettle();
    expect(jsonDecode(fx.where('POST', '/activate').single.body), {'password': 'Long-activation-password'});
    expect(fx.where('POST', '/create'), isEmpty);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Invited'), findsNothing);
  });

  testWidgets('duplicate email error keeps the Add admin form open for correction', (t) async {
    final fx = await pumpApp(t);
    await signIn(t);
    await t.tap(find.text('Admins'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add-platform-admin')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('new-admin-name')), 'Existing');
    await t.enterText(find.byKey(const Key('new-admin-email')), 'existing@example.test');
    await t.enterText(find.byKey(const Key('new-admin-password')), 'Long-existing-password');
    fx.overrides['POST /platform/admins/create'] = (409, {'code': 'duplicate_email', 'message': 'An admin with this email already exists'});
    await t.tap(find.byKey(const Key('save-platform-admin')));
    await t.pumpAndSettle();
    expect(find.text('An admin with this email already exists'), findsOneWidget);
    expect(find.byKey(const Key('new-admin-password')), findsOneWidget);
    expect(find.byKey(const Key('save-platform-admin')), findsOneWidget);
  });

  testWidgets('P11: the audit log page lists events', (t) async {
    await pumpApp(t);
    await signIn(t);
    await t.tap(find.byKey(const Key('nav-Audit log')));
    await t.pumpAndSettle();
    expect(find.text('No history yet'), findsNothing);
    expect(find.byType(ExpansionTile), findsWidgets);
  });

  testWidgets('audit log: odd before/after shapes still render; All activity keeps the restaurant filter; Clear resets', (t) async {
    final fx = await pumpApp(t);
    final audit = FixtureApi.fixture('GET_platform_audit.json')! as Map<String, dynamic>;
    final items = [...(audit['items'] as List)];
    items.add({...(items.first as Map), 'id': 'odd', 'action': 'menu.bulk_import', 'before': ['a', 'b'], 'after': 'text'});
    // shapes found in the live database: role changes and dish-size edits store lists
    items.add({...(items.first as Map), 'id': 'roles', 'action': 'platform.admin.roles_changed', 'before': [{'id': 'r1', 'name': 'Onboarding Admin'}], 'after': [{'id': 'r1', 'name': 'Onboarding Admin'}, {'id': 'r2', 'name': 'Platform Auditor'}]});
    items.add({...(items.first as Map), 'id': 'sizes', 'action': 'menu.variants_updated', 'before': [{'code': 'SC-1', 'name': 'Regular', 'available': true, 'pricePaise': 25000}], 'after': null});
    fx.overrides['GET /platform/audit'] = (200, {...audit, 'items': items});
    await signIn(t);
    await t.tap(find.byKey(const Key('nav-Audit log')));
    await t.pumpAndSettle();
    expect(find.text('Bulk import'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNWidgets(items.length));
    await t.tap(find.text('Admin roles changed'));
    await t.pumpAndSettle();
    expect(find.text('Onboarding Admin → Onboarding Admin, Platform Auditor'), findsOneWidget);

    await t.tap(find.byKey(const Key('audit-cat-auth_failure')));
    await t.pumpAndSettle();
    expect(Uri.parse('${fx.calls.last.url}').queryParameters['category'], 'auth_failure');
    await t.enterText(find.byKey(const Key('audit-search')), 'payment');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(Uri.parse('${fx.calls.last.url}').queryParameters['q'], 'payment');
    // "All activity" drops only the category; the text filter stays applied
    await t.tap(find.byKey(const Key('audit-cat-all')));
    await t.pumpAndSettle();
    final q = Uri.parse('${fx.calls.last.url}').queryParameters;
    expect(q['category'], isNull);
    expect(q['q'], 'payment');
    await t.tap(find.byKey(const Key('audit-clear')));
    await t.pumpAndSettle();
    expect(Uri.parse('${fx.calls.last.url}').queryParameters['q'], isNull);
    expect(find.byKey(const Key('audit-clear')), findsNothing);
  });

  testWidgets('register restaurant: show password, one billing cycle for every plan, sent with the request', (t) async {
    final fx = await pumpApp(t);
    fx.overrides['GET /plans'] = (200, [
      {'id': 'a', 'code': 'standard', 'name': 'Standard', 'tier': 1, 'pricePaise': 99900, 'yearlyPricePaise': 999000, 'billingCycle': 'monthly', 'featureFlags': [], 'limits': {}},
      {'id': 'b', 'code': 'premium', 'name': 'Premium', 'tier': 3, 'pricePaise': 249900, 'yearlyPricePaise': 2499000, 'billingCycle': 'yearly', 'featureFlags': [], 'limits': {}},
    ]);
    fx.overrides['POST /restaurants'] = (201, {'status': 'pending', 'emailSent': true});
    await signIn(t);
    await t.tap(find.byKey(const Key('nav-Restaurants')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('register-restaurant')));
    await t.pumpAndSettle();

    final pw = find.descendant(of: find.byKey(const Key('register-password')), matching: find.byType(EditableText));
    expect(t.widget<EditableText>(pw).obscureText, isTrue);
    await t.tap(find.byKey(const Key('register-show-password')));
    await t.pump();
    expect(t.widget<EditableText>(pw).obscureText, isFalse);

    await t.tap(find.byKey(const Key('register-plan-monthly')));
    await t.pumpAndSettle();
    expect(find.text('Standard · ₹999 / month'), findsWidgets);
    expect(find.text('Premium · ₹2,499 / month'), findsWidgets);
    await t.tapAt(const Offset(5, 5)); // close the menu
    await t.pumpAndSettle();
    await t.tap(find.text('Pay yearly'));
    await t.pumpAndSettle();
    expect(find.text('Standard · ₹9,990 / year'), findsOneWidget);

    // tapping outside the form does not close it
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(find.text('Register restaurant'), findsWidgets);
    expect(find.byKey(const Key('register-cycle')), findsOneWidget);

    await t.enterText(find.widgetWithText(TextFormField, 'Owner email'), 'o@example.com');
    await t.enterText(find.widgetWithText(TextFormField, 'Owner name'), 'Owner');
    await t.enterText(find.widgetWithText(TextFormField, 'Restaurant name'), 'Cafe');
    await t.tap(find.text('Send verification'));
    await t.pumpAndSettle();
    final sent = jsonDecode(fx.where('POST', '/restaurants').single.body) as Map;
    expect(sent['billingCycle'], 'yearly');
    expect(sent['planCode'], 'standard');
  });

  testWidgets('edit roles shows what a role can do in words, not permission codes', (t) async {
    await pumpApp(t);
    await signIn(t);
    await t.tap(find.byKey(const Key('nav-Admins')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('refresh-admins')), findsOneWidget);
    await t.tap(find.byTooltip('Actions').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Edit roles'));
    await t.pumpAndSettle();
    expect(find.textContaining('platform.restaurant.read'), findsNothing);
    expect(find.textContaining('See restaurants'), findsWidgets);
  });
}
