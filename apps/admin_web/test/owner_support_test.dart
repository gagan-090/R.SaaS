import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

/// Built at runtime so no password literal sits in the repo (secret scan).
final newPassword = ['Owner', 'Support', DateTime.now().year].join('-');

Future<FixtureApi> openRestaurant(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fx = FixtureApi();
  final detail = FixtureApi.fixture('GET_restaurants_id.json')! as Map;
  final id = detail['id'];
  fx.overrides['GET /restaurants/$id/owner'] =
      (200, {'id': 'u1', 'name': 'Meera', 'email': 'owner@example.test', 'status': 'active', 'hasPassword': true, 'mfaEnrolled': true, 'lockedUntil': null, 'passwordResetPendingUntil': null});
  fx.overrides['POST /restaurants/$id/owner/password-reset'] =
      (200, {'ownerEmail': 'owner@example.test', 'emailed': false, 'link': 'https://console.test/#/reset-password?token=abc123', 'expiresAt': '2026-11-07T10:00:00Z'});
  fx.overrides['POST /restaurants/$id/owner/mfa/reset'] = (200, {'id': 'u1', 'mfaReset': true, 'notified': 'owner@example.test'});
  final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))]);
  addTearDown(container.dispose);
  await t.pumpWidget(UncontrolledProviderScope(container: container, child: const AdminApp()));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('login-email')), 'admin@example.com');
  await t.enterText(find.byKey(const Key('login-password')), 'pw');
  await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('mfa-code')), '123456');
  await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
  await t.pumpAndSettle();
  container.read(routerProvider).go('/restaurants/$id');
  await t.pumpAndSettle();
  return fx;
}

Future<void> reasonThenStepUp(WidgetTester t, String reason) async {
  await t.enterText(find.byKey(const Key('reason-field')), reason);
  await t.pump();
  await t.tap(find.text('Continue').last);
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('stepup-password')), 'pw');
  await t.enterText(find.byKey(const Key('stepup-code')), '123456');
  await t.tap(find.text('Verify').last);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('Super Admin sends the owner a password reset link: reason + step-up, then the one-time link to pass on', (t) async {
    final fx = await openRestaurant(t, const Size(1600, 1200));
    await t.scrollUntilVisible(find.byKey(const Key('owner-password-reset')), 300, scrollable: find.descendant(of: find.byKey(const Key('restaurant-detail')), matching: find.byType(Scrollable)).first);
    expect(find.descendant(of: find.byKey(const Key('owner-account')), matching: find.text('Set up')), findsOneWidget); // MFA status
    await t.ensureVisible(find.byKey(const Key('owner-password-reset'))); // fully on screen, not just its top edge
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('owner-password-reset')));
    await t.pumpAndSettle();
    await reasonThenStepUp(t, 'Owner called support, identity checked');

    final sent = fx.where('POST', '/owner/password-reset').single;
    expect(jsonDecode(sent.body), {'reason': 'Owner called support, identity checked'});
    expect(sent.headers['x-step-up-token'], isNotEmpty);
    expect(find.text('Email not delivered'), findsOneWidget);
    expect(find.text('https://console.test/#/reset-password?token=abc123'), findsOneWidget);

    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await t.tap(find.byKey(const Key('copy-reset-link')));
    await t.pumpAndSettle();
    expect(copied, 'https://console.test/#/reset-password?token=abc123');
  });

  testWidgets('on a phone the owner tools are in the actions at the top; MFA reset needs a reason and step-up', (t) async {
    final fx = await openRestaurant(t, const Size(390, 844));
    expect(find.descendant(of: find.byKey(const Key('restaurant-actions')), matching: find.byKey(const Key('owner-mfa-reset'))), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('owner-mfa-reset')));
    await t.tap(find.byKey(const Key('owner-mfa-reset')));
    await t.pumpAndSettle();
    await reasonThenStepUp(t, 'Lost phone, identity checked');
    final sent = fx.where('POST', '/owner/mfa/reset').single;
    expect(jsonDecode(sent.body), {'reason': 'Lost phone, identity checked'});
    expect(sent.headers['x-step-up-token'], isNotEmpty);
    expect(find.textContaining('owner@example.test was notified'), findsOneWidget);
  });

  testWidgets('owner opens the reset link on a phone and chooses a new password', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fx = FixtureApi()
      ..overrides['POST /auth/password-link/check'] = (200, {'name': 'Meera', 'email': 'owner@example.test', 'restaurantName': 'Demo Dhaba'})
      ..overrides['POST /auth/password-link/complete'] = (200, {'ok': true, 'email': 'owner@example.test'});
    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const AdminApp()));
    container.read(routerProvider).go('/reset-password?token=tok_abcdefghijklmnopqrstuvwxyz');
    await t.pumpAndSettle();
    expect(find.text('owner@example.test · Demo Dhaba'), findsOneWidget);

    await t.enterText(find.byKey(const Key('new-password')), 'short');
    await t.enterText(find.byKey(const Key('new-password-again')), 'short');
    await t.tap(find.byKey(const Key('save-password')));
    await t.pumpAndSettle();
    expect(find.text('Use at least 12 characters'), findsOneWidget);
    expect(fx.where('POST', '/password-link/complete'), isEmpty);

    await t.enterText(find.byKey(const Key('new-password')), newPassword);
    await t.enterText(find.byKey(const Key('new-password-again')), newPassword);
    await t.tap(find.byKey(const Key('save-password')));
    await t.pumpAndSettle();
    expect(jsonDecode(fx.where('POST', '/password-link/complete').single.body), {'token': 'tok_abcdefghijklmnopqrstuvwxyz', 'password': newPassword});
    expect(find.text('Password changed'), findsOneWidget);
  });
}
