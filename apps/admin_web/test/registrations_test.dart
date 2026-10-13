import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

Map<String, dynamic> reg(String id, String name, String state, {String? error}) => {
      'id': id, 'restaurantName': name, 'ownerName': 'Meera', 'ownerEmail': 'meera@example.test', 'planCode': 'premium', 'planName': 'Premium',
      'createdAt': DateTime.now().subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
      'expiresAt': DateTime.now().add(Duration(hours: state == 'expired' ? -5 : 70)).toUtc().toIso8601String(),
      'lastSentAt': DateTime.now().subtract(const Duration(hours: 2)).toUtc().toIso8601String(), 'sendCount': 1, 'lastEmailError': error,
      'cancelledAt': null, 'cancelReason': null, 'state': state,
    };

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('pending registrations are visible: dashboard card → Awaiting tab; resend and cancel', (t) async {
    t.view.physicalSize = const Size(1600, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fx = FixtureApi()
      ..overrides['GET /restaurants/registrations'] = (200, {
        'counts': {'awaiting': 1, 'expired': 1},
        'items': [reg('r1', 'Spice Route', 'awaiting', error: 'You can only send testing emails to your own email address'), reg('r2', 'Old Cafe', 'expired')],
      })
      ..overrides['POST /restaurants/registrations/r1/resend'] = (200, {'id': 'r1', 'emailSent': false, 'emailError': 'You can only send testing emails to your own email address', 'verifyUrl': 'http://192.168.1.25:8080/#/verify-email?token=new'})
      ..overrides['POST /restaurants/registrations/r2/cancel'] = (200, {'id': 'r2', 'cancelledAt': '2026-10-13T10:00:00Z'});
    await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('login-email')), 'admin@example.com');
    await t.enterText(find.byKey(const Key('login-password')), 'pw');
    await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('mfa-code')), '123456');
    await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
    await t.pumpAndSettle();

    await t.tap(find.text('Awaiting verification'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('registration-Spice Route')), findsOneWidget);
    expect(find.textContaining('Last email not delivered'), findsOneWidget);
    expect(find.textContaining('expires in'), findsOneWidget);
    expect(find.text('Link expired'), findsWidgets);

    await t.tap(find.byKey(const Key('resend-Spice Route')));
    await t.pumpAndSettle();
    expect(find.text('Email not delivered'), findsOneWidget);
    expect(find.text('http://192.168.1.25:8080/#/verify-email?token=new'), findsOneWidget);
    await t.tap(find.widgetWithText(PrimaryButton, 'Done'));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('cancel-Old Cafe')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('reason-field')), 'Owner changed their mind');
    await t.pump();
    await t.tap(find.widgetWithText(DangerButton, 'Cancel registration'));
    await t.pumpAndSettle();
    expect(jsonDecode(fx.where('POST', '/restaurants/registrations/r2/cancel').single.body), {'reason': 'Owner changed their mind'});
  });
}
