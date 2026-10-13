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
    expect(find.text('Recent audit events'.toUpperCase()), findsOneWidget);
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
}
