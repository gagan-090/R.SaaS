import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/api/api_client.dart';
import 'package:rsaas_admin_web/app.dart';
import 'package:rsaas_admin_web/screens/plans_screen.dart';
import 'package:rsaas_admin_web/state/providers.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fixture_api.dart';

Map<String, dynamic> plan(String code, String name, int paise, {bool archived = false}) => {
      'id': 'id-$code', 'code': code, 'name': name, 'pricePaise': paise, 'billingCycle': 'monthly', 'archived': archived, 'activeLicenses': 2,
      'featureFlags': ['tables', 'menu', 'billing'], 'limits': {'branches': 1, 'devicesPerBranch': null},
    };

Future<FixtureApi> superAdminOnPlans(WidgetTester t, {Brightness brightness = Brightness.light, FixtureApi? api}) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  final fx = api ?? (FixtureApi()..overrides['GET /plans'] = (200, [plan('standard', 'Standard', 0), plan('premium', 'Premium', 249900)]));
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

  test('every server feature is configurable in the plan editor', () {
    final source = File('../api/src/common/permissions.ts').readAsStringSync();
    final catalog = source.split('export const FEATURE_FLAGS = {')[1].split('} as const;')[0];
    final flags = RegExp(r"^\s*(?:'([^']+)'|(\w+)):", multiLine: true)
        .allMatches(catalog).map((m) => m[1] ?? m[2]!).toSet();
    expect(featureGroups.expand((g) => g.$2).map((f) => f.$1).toSet(), flags);
  });

  testWidgets('existing plans can enable staff sign-in, dragging and both Excel imports', (t) async {
    final fx = await superAdminOnPlans(t);
    fx.overrides['PATCH /plans/id-premium'] = (200, {...plan('premium', 'Premium', 249900), 'licensesUpdated': 2});
    await t.tap(find.byKey(const Key('plan-menu-premium')));
    await t.pumpAndSettle();
    await t.tap(find.text('Edit price & features'));
    await t.pumpAndSettle();
    for (final f in ['staff_portal', 'floor.editor', 'import.excel', 'roles.custom', 'expenses']) {
      final chip = find.byKey(Key('feature-$f'));
      await t.ensureVisible(chip);
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(t.widget<FilterChip>(chip).selected, isTrue);
    }
    await t.tap(find.byKey(const Key('save-plan')));
    await t.pumpAndSettle();
    final sent = jsonDecode(fx.where('PATCH', '/plans/id-premium').single.body) as Map;
    expect(sent['featureFlags'], containsAll(['tables', 'menu', 'billing', 'staff_portal', 'floor.editor', 'import.excel', 'roles.custom', 'expenses']));
    expect(sent['pricePaise'], 249900);
    expect(find.textContaining('2 restaurants on this plan updated now'), findsOneWidget);
  });

  testWidgets('Super Admin sees prices, adds a plan with a price, features and limits', (t) async {
    final fx = await superAdminOnPlans(t);
    expect(find.text('₹2,499 / month'), findsOneWidget);
    expect(find.text('2 restaurant(s) on this plan'), findsWidgets);
    fx.overrides['POST /plans'] = (201, plan('pro_plus', 'Pro Plus', 149900));
    await t.tap(find.byKey(const Key('add-plan')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('plan-name')), 'Pro Plus');
    await t.enterText(find.byKey(const Key('plan-price')), '1499');
    await t.enterText(find.byKey(const Key('plan-yearly-price')), '12000');
    await t.ensureVisible(find.byKey(const Key('feature-kds')));
    await t.tap(find.byKey(const Key('feature-kds')));
    final dialogYearly = find.descendant(of: find.byType(HPDialog), matching: find.text('Yearly'));
    await t.ensureVisible(dialogYearly);
    await t.tap(dialogYearly);
    await t.pump();
    await t.tap(find.byKey(const Key('save-plan')));
    await t.pumpAndSettle();
    final body = jsonDecode(fx.where('POST', '/plans').single.body) as Map;
    expect(body['code'], 'pro_plus', reason: 'code derived from the name');
    expect(body['pricePaise'], 149900);
    expect(body['yearlyPricePaise'], 1200000);
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

  testWidgets('appearance: white by default even on a dark device; a plain Light / Dark switch that always changes the look', (t) async {
    await superAdminOnPlans(t, brightness: Brightness.dark);
    Brightness now() => Theme.of(t.element(find.byType(Scaffold).last)).brightness;
    expect(now(), Brightness.light);
    expect(Theme.of(t.element(find.byType(Scaffold).last)).scaffoldBackgroundColor, HPColors.white);
    // no "Auto": on a light device it looked identical to Light, so the first two choices seemed to do nothing
    expect(find.byTooltip('Follow this device'), findsNothing);
    await t.tap(find.byTooltip('Dark'));
    await t.pumpAndSettle();
    expect(now(), Brightness.dark);
    await t.tap(find.byTooltip('Light'));
    await t.pumpAndSettle();
    expect(now(), Brightness.light);
  });

  testWidgets('Monthly / Yearly switch reprices every card; Show archived lists only archived plans', (t) async {
    final fx = await superAdminOnPlans(t);
    expect(find.text('₹2,499 / month'), findsOneWidget);
    await t.tap(find.text('Yearly'));
    await t.pumpAndSettle();
    expect(find.text('₹2,499 / month'), findsNothing);
    expect(find.text('₹24,990 / year'), findsOneWidget); // no yearly price stored: 10 × monthly
    expect(find.textContaining('Works out to'), findsWidgets);

    fx.overrides['GET /plans'] = (200, [plan('standard', 'Standard', 0), plan('premium', 'Premium', 249900), plan('legacy', 'Legacy', 50000, archived: true)]);
    await t.tap(find.byKey(const Key('plans-archived')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('plan-legacy')), findsOneWidget);
    expect(find.byKey(const Key('plan-standard')), findsNothing);
    expect(find.byKey(const Key('plan-premium')), findsNothing);
  });

  testWidgets('plan cards sit side by side at the same height', (t) async {
    await superAdminOnPlans(t);
    final a = t.getRect(find.byKey(const Key('plan-standard')));
    final b = t.getRect(find.byKey(const Key('plan-premium')));
    expect(a.top, b.top);
    expect(a.height, b.height);
  });

  testWidgets('higher plans list only what they add to the plan below; cards stay the same size', (t) async {
    final fx = FixtureApi();
    Map<String, dynamic> tiered(String code, String name, int tier, List<String> flags) => {...plan(code, name, 99900 * tier), 'tier': tier, 'featureFlags': flags};
    fx.overrides['GET /plans'] = (200, [
      tiered('premium', 'Premium', 3, ['tables', 'menu', 'billing', 'floors', 'kds', 'inventory']),
      tiered('standard', 'Standard', 1, ['tables', 'menu', 'billing']),
      tiered('professional', 'Professional', 2, ['tables', 'menu', 'billing', 'floors']),
    ]);
    await superAdminOnPlans(t, api: fx);
    expect(find.text('Everything in Standard, plus:'), findsOneWidget);
    expect(find.text('Everything in Professional, plus:'), findsOneWidget);
    expect(find.text('Menu, categories, tax'), findsOneWidget); // listed once, on Standard only
    expect(find.text('Kitchen display'), findsOneWidget);
    final h = {for (final c in ['standard', 'professional', 'premium']) t.getRect(find.byKey(Key('plan-$c'))).height};
    expect(h.length, 1);
  });
}
