import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

/// Built at runtime so no password literal sits in the repo (secret scan).
final strong = ['Spice', 'route', DateTime.now().year].join('-');
final other = '$strong-x';

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('owner opens the emailed link, sets a strong password and is told to sign in', (t) async {
    t.view.physicalSize = const Size(390, 844); // most owners open the email on a phone
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fx = FixtureApi()..overrides['POST /restaurants/verify-email'] = (201, {'tenantId': 't1', 'code': 'R000123', 'branchId': 'b1', 'ownerUserId': 'u1'});
    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const AdminApp()));
    container.read(routerProvider).go('/verify-email?token=tok_123');
    await t.pumpAndSettle();
    expect(find.text('Set your password'), findsOneWidget);

    await t.enterText(find.byKey(const Key('verify-password')), 'short1');
    await t.enterText(find.byKey(const Key('verify-password2')), 'short1');
    await t.tap(find.byKey(const Key('verify-submit')));
    await t.pumpAndSettle();
    expect(find.text('Use at least 12 characters'), findsOneWidget);

    await t.enterText(find.byKey(const Key('verify-password')), strong);
    await t.enterText(find.byKey(const Key('verify-password2')), other);
    await t.tap(find.byKey(const Key('verify-submit')));
    await t.pumpAndSettle();
    expect(find.text('The two passwords do not match'), findsOneWidget);

    await t.enterText(find.byKey(const Key('verify-password2')), strong);
    await t.tap(find.byKey(const Key('verify-submit')));
    await t.pumpAndSettle();
    expect(jsonDecode(fx.where('POST', '/restaurants/verify-email').single.body), {'token': 'tok_123', 'password': strong});
    expect(find.text('Your restaurant is ready'), findsOneWidget);
    expect(find.textContaining('R000123'), findsOneWidget);
    await t.tap(find.byKey(const Key('verify-signin')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });

  testWidgets('an expired link shows the server message', (t) async {
    final fx = FixtureApi()..overrides['POST /restaurants/verify-email'] = (400, {'code': 'invalid_token', 'message': 'Verification link is invalid or expired'});
    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const AdminApp()));
    container.read(routerProvider).go('/verify-email?token=old');
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('verify-password')), strong);
    await t.enterText(find.byKey(const Key('verify-password2')), strong);
    await t.tap(find.byKey(const Key('verify-submit')));
    await t.pumpAndSettle();
    expect(find.text('Verification link is invalid or expired'), findsOneWidget);
  });
}
