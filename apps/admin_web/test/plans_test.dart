import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

Map<String, dynamic> plan(String code, String name, int paise, {bool archived = false}) => {
      'id': 'id-$code', 'code': code, 'name': name, 'pricePaise': paise, 'billingCycle': 'monthly', 'archived': archived, 'activeLicenses': 2,
      'featureFlags': ['tables', 'menu', 'billing'], 'limits': {'branches': 1, 'devicesPerBranch': null},
    };

Future<FixtureApi> superAdminOnPlans(WidgetTester t, {Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  final fx = FixtureApi()..overrides['GET /plans'] = (200, [plan('standard', 'Standard', 0), plan('premium', 'Premium', 249900)]);
  await t.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(ApiClient(baseUrl: 'http://api.test/api/v1', client: fx.client()))], child: const AdminApp()));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('login-email')), 'admin@example.com');
  await t.enterText(find.byKey(const Key('login-password')), 'pw');
  await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('mfa-code')), '123456');
  await t.tap(find.widgetWithText(PrimaryButton, 'Verify'));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('nav-Plans')));
  await t.pumpAndSettle();
  return fx;
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  testWidgets('Super Admin sees prices, adds a plan with a price, features and limits', (t) async {
    final fx = await superAdminOnPlans(t);
    expect(find.text('₹2,499 / month'), findsOneWidget);
    expect(find.text('2 restaurant(s) on this plan'), findsWidgets);
    fx.overrides['POST /plans'] = (201, plan('pro_plus', 'Pro Plus', 149900));
    await t.tap(find.byKey(const Key('add-plan')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('plan-name')), 'Pro Plus');
    await t.enterText(find.byKey(const Key('plan-price')), '1499');
    await t.tap(find.byKey(const Key('feature-kds')));
    await t.tap(find.text('Yearly'));
    await t.pump();
    await t.tap(find.byKey(const Key('save-plan')));
    await t.pumpAndSettle();
    final body = jsonDecode(fx.where('POST', '/plans').single.body) as Map;
    expect(body['code'], 'pro_plus', reason: 'code derived from the name');
    expect(body['pricePaise'], 149900);
    expect(body['billingCycle'], 'yearly');
    expect(body['featureFlags'], containsAll(['tables', 'billing', 'kds']));
    expect((body['limits'] as Map)['branches'], 1);
    expect((body['limits'] as Map)['devicesPerBranch'], isNull, reason: 'blank = unlimited');
  });

  testWidgets('changing a price sends paise; archiving asks first and warns about restaurants on the plan', (t) async {
    final fx = await superAdminOnPlans(t);
    fx.overrides['PATCH /plans/id-standard'] = (200, plan('standard', 'Standard', 99900));
    await t.tap(find.byKey(const Key('plan-menu-standard')));
    await t.pumpAndSettle();
    await t.tap(find.text('Edit price & features'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('plan-price')), '999');
    await t.tap(find.byKey(const Key('save-plan')));
    await t.pumpAndSettle();
    expect((jsonDecode(fx.where('PATCH', '/plans/id-standard').last.body) as Map)['pricePaise'], 99900);

    await t.tap(find.byKey(const Key('plan-menu-standard')));
    await t.pumpAndSettle();
    await t.tap(find.text('Archive'));
    await t.pumpAndSettle();
    expect(find.textContaining('2 restaurant(s) are on this plan'), findsOneWidget);
    await t.tap(find.widgetWithText(DangerButton, 'Archive'));
    await t.pumpAndSettle();
    expect(jsonDecode(fx.where('PATCH', '/plans/id-standard').last.body), {'archived': true});
  });

  testWidgets('appearance: Light overrides a dark device, Auto follows it again', (t) async {
    await superAdminOnPlans(t, brightness: Brightness.dark);
    Brightness now() => Theme.of(t.element(find.byType(Scaffold).last)).brightness;
    expect(now(), Brightness.dark);
    await t.tap(find.byTooltip('Light'));
    await t.pumpAndSettle();
    expect(now(), Brightness.light);
    await t.tap(find.byTooltip('Follow this device'));
    await t.pumpAndSettle();
    expect(now(), Brightness.dark);
  });
}
